#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把当前工作目录的文件同步到 GitHub（走 REST API，不用 git push）。

为什么不用 git push：
  本机出网走白名单代理，github.com 的 CONNECT 被拦（502），只有 api.github.com 通。
  所以 git push / fetch 全部不可用，改由 Git Data API 逐文件建 blob → 建 tree → 建 commit → 移动分支。

用法：
  python tool/publish.py                    # 提交并移动 main 分支
  python tool/publish.py --message "xxx"    # 自定义提交信息
  python tool/publish.py --dry-run          # 只打印要上传的文件和大小

令牌来源：环境变量 GH_TOKEN，或解析本仓库 git remote URL 里的 https://<token>@github.com/...
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OWNER = "Amanxie"
REPO = "plc-monitor-app"
BRANCH = "main"
API = "https://api.github.com"

SKIP_DIRS = {".git", "build", ".dart_tool", ".gradle", ".cxx", ".idea", "shots", "__pycache__"}
SKIP_NAMES = {".packages", ".flutter-plugins", ".flutter-plugins-dependencies", "local.properties"}
# 本机调试临时文件（截图 / UI dump）绝不进仓库
SKIP_RE = re.compile(r'^(ui\d*\.png|ui_dump\.xml|ui_texts\.txt|clickables\.txt)$')
MAX_BLOB = 25 * 1024 * 1024


def token():
    t = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if t:
        return t.strip()
    try:
        url = subprocess.run(["git", "remote", "get-url", "origin"], cwd=ROOT,
                             capture_output=True, text=True).stdout.strip()
        if "@github.com" in url:
            return url.split("://", 1)[1].split("@", 1)[0].split(":", 1)[-1]
    except Exception:
        pass
    sys.exit("找不到令牌：设置环境变量 GH_TOKEN，或在 git remote 里带上 https://<token>@github.com/...")


def api(method, path, payload=None, timeout=900, allow=()):
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
    req = urllib.request.Request(f"{API}{path}", data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        if e.code in allow:
            return {}
        detail = e.read().decode("utf-8", "ignore")[:400]
        sys.exit(f"API {method} {path} 失败 {e.code}: {detail}")


def collect():
    """收集要上传的文件（含 .gitignore 之外的都传，但排除构建产物/密钥）。"""
    out = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name in SKIP_NAMES or SKIP_RE.match(name) or name.endswith((".jks", ".keystore", ".iml")):
                continue
            p = Path(dirpath) / name
            rel = p.relative_to(ROOT).as_posix()
            if rel in ("android/key.properties",):
                continue
            out.append((rel, p))
    out.sort()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--message", default="sync: 更新文件")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    files = collect()
    total = sum(p.stat().st_size for _, p in files)
    print(f"待上传 {len(files)} 个文件，共 {total/1048576:.1f} MB")
    if args.dry_run:
        for rel, p in files:
            if p.stat().st_size > 1048576:
                print(f"  {rel}  {p.stat().st_size/1048576:.1f} MB")
        return

    # 当前分支头（首次为空仓库时可能是 404）
    head = api("GET", f"/repos/{OWNER}/{REPO}/git/ref/heads/{BRANCH}", allow=(404, 409))
    parent = head.get("object", {}).get("sha")
    base_tree = None
    if parent:
        c = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{parent}")
        base_tree = c["tree"]["sha"]
        print(f"当前分支头 {parent[:10]}，在其上叠加")

    entries = []
    for i, (rel, p) in enumerate(files, 1):
        raw = p.read_bytes()
        size = len(raw)
        if size > MAX_BLOB:
            # GitHub Git Data API 单次 JSON 上限约 100 MB（base64 后膨胀 33%），大包走 Releases
            print(f"[{i}/{len(files)}] 跳过 {rel}（{size/1048576:.1f} MB > {MAX_BLOB/1048576:.0f} MB，APK 请走 Releases）", flush=True)
            continue
        blob = api("POST", f"/repos/{OWNER}/{REPO}/git/blobs",
                   {"content": base64.b64encode(raw).decode(), "encoding": "base64"})
        entries.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})
        if i % 10 == 0:
            print(f"[{i}/{len(files)}] {rel} ok", flush=True)

    tree_payload = {"tree": entries}
    if base_tree:
        tree_payload["base_tree"] = base_tree
    tree = api("POST", f"/repos/{OWNER}/{REPO}/git/trees", tree_payload)
    commit = api("POST", f"/repos/{OWNER}/{REPO}/git/commits",
                 {"message": args.message, "tree": tree["sha"],
                  "parents": [parent] if parent else []})

    if parent:
        api("PATCH", f"/repos/{OWNER}/{REPO}/git/refs/heads/{BRANCH}",
            {"sha": commit["sha"], "force": False})
    else:
        api("POST", f"/repos/{OWNER}/{REPO}/git/refs",
            {"ref": f"refs/heads/{BRANCH}", "sha": commit["sha"]})

    print(f"已推送 commit {commit['sha'][:10]}：{args.message}")
    print(f"https://github.com/{OWNER}/{REPO}")


if __name__ == "__main__":
    main()
