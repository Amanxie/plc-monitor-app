#!/usr/bin/env bash
# Render 静态站的构建脚本：把 server/ 复制成发布目录，并把 APK 从 Release 抓下来放进 releases/
# 这样仓库里不用存 50MB 二进制，APK 仍然由 Render 的 CDN 提供（国内访问比 GitHub 稳）
set -euo pipefail

version_json="server/version.json"
src=$(python3 -c "import json;print(json.load(open('$version_json')).get('apkSource',''))")
name=$(basename "$src")

if [ -z "$src" ] || [ "$name" = "" ]; then
  echo "version.json 里没有 apkSource，跳过下载"
  rm -rf dist && mkdir -p dist && cp -r server/. dist/
  exit 0
fi

rm -rf dist && mkdir -p dist/releases
cp -r server/. dist/

echo "抓取 APK: $src"
curl -fsSL --retry 3 --retry-delay 2 -o "dist/releases/$name" "$src"
ls -lh "dist/releases/$name"
