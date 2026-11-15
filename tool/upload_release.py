#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 APK 传成 GitHub Release 附件（仓库里不放 50MB 二进制）。

用法：
  python tool/upload_release.py --version 1.7.2 --apk server/releases/plc-monitor-v1.7.2.apk --notes-file notes.txt

产物：Release 附件 URL，写进 server/version.json 的 "apk" 字段。
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OWNER = "Amanxie"
REPO = "plc-monitor-app"
API = "https://api.github.com"
UPLOAD = "https://uploads.github.com"


def token():
    t = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if t:
        return t.strip()
    import subprocess
    url = subprocess.run(["git", "remote", "get-url", "origin"], cwd=ROOT,
                         capture_output=True, text=True).stdout.strip()
    if "@github.com" in url:
        return url.split("://", 1)[1].split("@", 1)[0].split(":", 1)[-1]
    sys.exit("找不到令牌：设置 GH_TOKEN")


def call(method, url, payload=None, timeout=300, allow=()):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    req.add_header("Accept", "application/vnd.github+json")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        if e.code in allow:
            return {"_code": e.code}
        sys.exit(f"{method} {url} 失败 {e.code}: {e.read().decode('utf-8','ignore')[:400]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--apk", required=True)
    ap.add_argument("--notes", default="常规优化与问题修复")
    args = ap.parse_args()

    apk = (ROOT / args.apk) if not Path(args.apk).is_absolute() else Path(args.apk)
    if not apk.exists():
        sys.exit(f"APK 不存在：{apk}")
    tag = f"v{args.version}"
    size = apk.stat().st_size
    print(f"APK {apk.name}  {size/1048576:.1f} MB")

    rel = call("GET", f"{API}/repos/{OWNER}/{REPO}/releases/tags/{tag}", allow=(404,))
    if "_code" in rel:
        notes = [n for n in args.notes.split("|") if n.strip()]
        rel = call("POST", f"{API}/repos/{OWNER}/{REPO}/releases", {
            "tag_name": tag, "name": tag, "body": "\n".join(f"- {n}" for n in notes),
            "draft": False, "prerelease": False,
        })
        print(f"已创建 Release {tag}")
    else:
        print(f"Release {tag} 已存在，重组附件")

    # 同名附件先删
    for a in rel.get("assets", []):
        if a["name"] == apk.name:
            call("DELETE", f"{API}/repos/{OWNER}/{REPO}/releases/assets/{a['id']}")
            print("已删除旧附件")

    data = apk.read_bytes()
    url = f"{UPLOAD}/repos/{OWNER}/{REPO}/releases/{rel['id']}/assets?name={apk.name}"
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Authorization", f"Bearer {token()}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("Content-Type", "application/vnd.android.package-archive")
    req.add_header("Content-Length", str(len(data)))
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=1800) as r:
            asset = json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"上传失败 {e.code}: {e.read().decode('utf-8','ignore')[:400]}")
    print(f"上传完成 {time.time()-t0:.0f}s → {asset['browser_download_url']}")
    print(f"URL={asset['browser_download_url']}")


if __name__ == "__main__":
    main()
