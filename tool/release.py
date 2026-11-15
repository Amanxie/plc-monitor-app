#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
一条命令发版：改版本号 → 编译 APK → 传成 GitHub Release 附件 → 写 version.json → 推送仓库
Render 检测到仓库变化会自动重建，App 端「检查更新」立刻能拿到新版本。

用法：
  python tool/release.py --version 1.7.3 --notes "修复xxx" --notes "新增yyy"
  python tool/release.py --version 1.7.3 --no-push      # 只出包和附件，不动仓库
  python tool/release.py --version 1.7.3 --skip-build   # 复用现有 APK 重发一次

注意：本机 git push 被网络代理拦住（github.com 502），仓库更新统一走 REST API（tool/publish.py）。
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
PY = sys.executable

DEFAULT_SDK = "D:/AI_Files/dev-tools/android-sdk"
DEFAULT_JDK = "D:/AI_Files/dev-tools/jdk-17.0.21+9"
FLUTTER = "D:/AI_Files/dev-tools/flutter/bin/flutter"


def read_current():
    m = re.search(r"^version:\s*([\d.]+)\+(\d+)\s*$", PUBSPEC.read_text(encoding="utf-8"), re.M)
    if not m:
        sys.exit("pubspec.yaml 里找不到 version: x.y.z+build")
    return m.group(1), int(m.group(2))


def write_version(version, build):
    text = PUBSPEC.read_text(encoding="utf-8")
    PUBSPEC.write_text(re.sub(r"^version:.*$", f"version: {version}+{build}", text, flags=re.M),
                       encoding="utf-8")
    main = MAIN.read_text(encoding="utf-8")
    main = re.sub(r"const kAppVersion = '[^']*';", f"const kAppVersion = '{version}';", main)
    main = re.sub(r"const kAppBuild = '[^']*';", f"const kAppBuild = '{build}';", main)
    MAIN.write_text(main, encoding="utf-8")


def build_apk():
    env = dict(os.environ)
    env.setdefault("ANDROID_HOME", DEFAULT_SDK)
    env.setdefault("JAVA_HOME", DEFAULT_JDK)
    flutter = FLUTTER if Path(FLUTTER).exists() else "flutter"
    print("[1/5] 编译 release APK ...", flush=True)
    if subprocess.run([flutter, "build", "apk", "--release"], cwd=ROOT, env=env).returncode != 0:
        sys.exit("编译失败")
    if not APK_OUT.exists():
        sys.exit(f"没找到产物：{APK_OUT}")


def upload(version, apk_path, notes):
    print("[2/5] 上传 APK 到 GitHub Release ...", flush=True)
    r = subprocess.run([PY, "tool/upload_release.py", "--version", version,
                        "--apk", str(apk_path), "--notes", "|".join(notes)],
                       cwd=ROOT, capture_output=True, text=True)
    print((r.stdout or "").strip()[-300:])
    if r.returncode != 0:
        sys.exit(f"上传失败：{r.stderr[-400:]}")
    for line in r.stdout.splitlines():
        if line.startswith("URL="):
            return line[4:].strip()
    sys.exit("上传成功但没拿到 URL")


def write_manifest(version, build, apk_path, url, notes):
    print("[3/5] 更新 version.json ...", flush=True)
    digest = hashlib.sha256(apk_path.read_bytes()).hexdigest()
    data = {
        "version": version,
        "build": build,
        "releasedAt": date.today().isoformat(),
        "apk": f"releases/{apk_path.name}",
        "apkSource": url,
        "size": apk_path.stat().st_size,
        "sha256": digest,
        "force": False,
        "notes": notes or ["常规优化与问题修复"],
    }
    VERSION_JSON.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"      v{version}(build {build}) · {data['size']/1048576:.1f} MB · sha256 {digest[:12]}…")


def publish(message):
    print("[4/5] 推送仓库（REST API）...", flush=True)
    r = subprocess.run([PY, "tool/publish.py", "--message", message], cwd=ROOT,
                       capture_output=True, text=True)
    print((r.stdout or r.stderr).strip()[-300:])
    if r.returncode != 0:
        sys.exit("推送失败")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", type=int)
    ap.add_argument("--notes", action="append")
    ap.add_argument("--skip-build", action="store_true")
    ap.add_argument("--no-push", action="store_true")
    args = ap.parse_args()

    cur_ver, cur_build = read_current()
    build = args.build if args.build else cur_build + 1
    if build <= cur_build:
        sys.exit(f"构建号必须递增：当前 {cur_build}，给的是 {build}")
    notes = args.notes or ["常规优化与问题修复"]

    print(f"旧版本 v{cur_ver}({cur_build}) → 新版本 v{args.version}({build})")
    write_version(args.version, build)
    if not args.skip_build:
        build_apk()
    else:
        print("[1/5] 跳过编译，复用现有 APK")

    RELEASES.mkdir(parents=True, exist_ok=True)
    target = RELEASES / f"plc-monitor-v{args.version}.apk"
    if not args.skip_build:
        shutil.copy2(APK_OUT, target)
    elif not target.exists():
        sys.exit(f"--skip-build 但 {target} 不存在")

    url = upload(args.version, target, notes)
    write_manifest(args.version, build, target, url, notes)
    if args.no_push:
        print("[5/5] --no-push，跳过推送")
    else:
        publish(f"release: v{args.version} (build {build})")
    print("完成。Render 会自动重建，约 1 分钟后生效。")
    print("清单：https://plc-monitor-app.onrender.com/version.json")


if __name__ == "__main__":
    main()
