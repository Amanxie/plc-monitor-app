#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
一条命令发版：改版本号 → 编译 APK → 放进 server/releases → 更新 version.json → 提交推送
Render 会自动重新发布，App 端「检查更新」立刻能拿到新版本。

用法：
  python tool/release.py --version 1.7.3 --notes "修复xxx" --notes "新增yyy"
  python tool/release.py --version 1.7.3 --no-push        # 只出包不推送
  python tool/release.py --version 1.7.3 --skip-build     # 用现有 APK（重发一次）

约定：
  - 版本号 x.y.z，构建号自动 +1（除非显式 --build）
  - APK 文件名 plc-monitor-vX.Y.Z.apk（ASCII，避免 URL 编码问题）
  - version.json 的 build 必须严格递增，App 靠它判断有无新版
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBSPEC = ROOT / "pubspec.yaml"
MAIN = ROOT / "lib" / "main.dart"
SERVER = ROOT / "server"
RELEASES = SERVER / "releases"
VERSION_JSON = SERVER / "version.json"
APK_OUT = ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"

DEFAULT_SDK = "D:/AI_Files/dev-tools/android-sdk"
DEFAULT_JDK = "D:/AI_Files/dev-tools/jdk-17.0.21+9"
FLUTTER = "D:/AI_Files/dev-tools/flutter/bin/flutter"


def read_current():
    text = PUBSPEC.read_text(encoding="utf-8")
    m = re.search(r"^version:\s*([\d.]+)\+(\d+)\s*$", text, re.M)
    if not m:
        sys.exit("pubspec.yaml 里找不到 version: x.y.z+build")
    return m.group(1), int(m.group(2))


def write_version(version, build):
    text = PUBSPEC.read_text(encoding="utf-8")
    text = re.sub(r"^version:.*$", f"version: {version}+{build}", text, flags=re.M)
    PUBSPEC.write_text(text, encoding="utf-8")

    main = MAIN.read_text(encoding="utf-8")
    main = re.sub(r"const kAppVersion = '[^']*';", f"const kAppVersion = '{version}';", main)
    main = re.sub(r"const kAppBuild = '[^']*';", f"const kAppBuild = '{build}';", main)
    MAIN.write_text(main, encoding="utf-8")


def build_apk():
    env = dict(os.environ)
    env.setdefault("ANDROID_HOME", DEFAULT_SDK)
    env.setdefault("JAVA_HOME", DEFAULT_JDK)
    flutter = FLUTTER if Path(FLUTTER).exists() else "flutter"
    print(f"[1/4] 编译 release APK ...")
    r = subprocess.run([flutter, "build", "apk", "--release"], cwd=ROOT, env=env)
    if r.returncode != 0:
        sys.exit("编译失败，检查上面的输出")
    if not APK_OUT.exists():
        sys.exit(f"没找到产物：{APK_OUT}")


def publish(version, build, notes):
    RELEASES.mkdir(parents=True, exist_ok=True)
    name = f"plc-monitor-v{version}.apk"
    target = RELEASES / name
    print(f"[2/4] 复制 APK → server/releases/{name}")
    shutil.copy2(APK_OUT, target)

    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    size = target.stat().st_size
    data = {
        "version": version,
        "build": build,
        "releasedAt": date.today().isoformat(),
        "apk": f"releases/{name}",
        "size": size,
        "sha256": digest,
        "force": False,
        "notes": notes or ["常规优化与问题修复"],
    }
    VERSION_JSON.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[3/4] version.json 已更新：v{version} (build {build}) · {size/1048576:.1f} MB · sha256 {digest[:12]}…")
    return name


def git_push(version, notes):
    print("[4/4] 提交并推送 ...")
    subprocess.run(["git", "add", "-A"], cwd=ROOT, check=True)
    msg = f"release: v{version}\n\n" + "\n".join(f"- {n}" for n in (notes or []))
    subprocess.run(["git", "commit", "-m", msg], cwd=ROOT, check=True)
    subprocess.run(["git", "push"], cwd=ROOT, check=True)
    print("已推送，Render 会自动重新发布（通常 30 秒内生效）")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True, help="新版本号，如 1.7.3")
    ap.add_argument("--build", type=int, help="构建号，默认当前 +1")
    ap.add_argument("--notes", action="append", help="更新说明，可多次传入")
    ap.add_argument("--skip-build", action="store_true", help="跳过编译，复用现有 APK")
    ap.add_argument("--no-push", action="store_true", help="只更新文件，不提交推送")
    args = ap.parse_args()

    cur_ver, cur_build = read_current()
    build = args.build if args.build else cur_build + 1
    if build <= cur_build:
        sys.exit(f"构建号必须递增：当前 {cur_build}，给的是 {build}")

    print(f"旧版本 v{cur_ver}({cur_build}) → 新版本 v{args.version}({build})")
    write_version(args.version, build)
    if not args.skip_build:
        build_apk()
    publish(args.version, build, args.notes)
    if not args.no_push:
        git_push(args.version, args.notes)
    print("完成。")


if __name__ == "__main__":
    main()
