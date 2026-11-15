#!/usr/bin/env bash
# Render 静态站构建脚本
#   1) server/ 整目录复制成发布目录 dist/
#   2) 按 server/version.json 里的 apkSource 从 GitHub Release 下载 APK 到 dist/releases/
# 仓库不存 50MB 二进制；手机下载走 Render CDN（国内比直连 GitHub 稳）
# 只用 sed/head/curl/wget，不依赖 python。
set -euo pipefail

VERSION_JSON="server/version.json"
[ -f "$VERSION_JSON" ] || { echo "缺少 $VERSION_JSON"; exit 1; }

# 提取 apkSource（允许为空）
SRC=$(sed -n 's/.*"apkSource"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_JSON" | head -n 1)
APK_REL=$(sed -n 's/.*"apk"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_JSON" | head -n 1)

rm -rf dist
mkdir -p dist
cp -r server/. dist/

if [ -z "$SRC" ]; then
  echo "version.json 未配置 apkSource，跳过 APK 下载"
  exit 0
fi

NAME=$(basename "$SRC")
mkdir -p dist/releases
TARGET="dist/releases/$NAME"

echo "下载 APK: $SRC"
if command -v curl >/dev/null 2>&1; then
  curl -fSL --retry 3 --retry-delay 3 --connect-timeout 20 -o "$TARGET" "$SRC"
else
  wget -q --tries=3 --timeout=60 -O "$TARGET" "$SRC"
fi

SIZE=$(wc -c < "$TARGET" | tr -d ' ')
echo "APK 大小: $SIZE 字节"
if [ "$SIZE" -lt 5000000 ]; then
  echo "APK 下载异常（小于 5MB），构建失败"
  exit 1
fi

# 保证 version.json 里的相对路径和实际文件名一致
if [ -n "$APK_REL" ] && [ "$(basename "$APK_REL")" != "$NAME" ]; then
  echo "警告：version.json 的 apk 路径($APK_REL)与下载文件名($NAME)不一致"
fi

# 顺手做一次 sha256 校验（有 sha256sum 才查）
if command -v sha256sum >/dev/null 2>&1; then
  EXPECT=$(sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_JSON" | head -n 1)
  ACTUAL=$(sha256sum "$TARGET" | cut -d' ' -f1)
  echo "sha256 期望=$EXPECT"
  echo "sha256 实际=$ACTUAL"
  if [ -n "$EXPECT" ] && [ "$EXPECT" != "$ACTUAL" ]; then
    echo "校验失败：APK 与 version.json 记录的 sha256 不一致"
    exit 1
  fi
fi

ls -lh "$TARGET"
echo "构建完成 -> dist/"
