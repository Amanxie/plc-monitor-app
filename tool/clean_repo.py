#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
清理 GitHub 仓库里误提交的文件（走 Git Data API，一次 commit 完成删除）。

用法：
  python tool/clean_repo.py ui.png ui2.png ui_dump.xml   # 按路径删除
  python tool/clean_repo.py --scan                       # 只列出根目录下的文件，不删

令牌来源与 publish.py 相同：GH_TOKEN 环境变量或 git remote URL 里的令牌。
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.request
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OWNER = "Amanxie"
REPO = "plc-monitor-app"
BRANCH = "main"
API = "https://api.github.com"


def token():
    t = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if t:
        return t.strip()
    url = subprocess.run(["git", "remote", "get-url", "origin"], cwd=ROOT,
                         capture_output=True, text=True).stdout.strip()
    if "@github.com" in url:
        return url.split("://", 1)[1].split("@", 1)[0].split(":", 1)[-1]
    sys.exit("找不到令牌：设置 GH_TOKEN")


def api(method, path, payload=None, allow=()):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(f"{API}{path}", data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    req.add_header("Accept", "application/vnd.github+json")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            body = r.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        if e.code in allow:
            return {"_code": e.code}
        sys.exit(f"{method} {path} 失败 {e.code}: {e.read().decode('utf-8','ignore')[:400]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="*", help="要删除的仓库内路径")
    ap.add_argument("--scan", action="store_true", help="只列出不删")
    args = ap.parse_args()

    head = api("GET", f"/repos/{OWNER}/{REPO}/git/ref/heads/{BRANCH}")["object"]["sha"]
    commit = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{head}")
    tree = api("GET", f"/repos/{OWNER}/{REPO}/git/trees/{commit['tree']['sha']}")

    if args.scan:
        for e in tree["tree"]:
            print(f"{e['type']:5} {e.get('size','')!s:>9} {e['path']}")
        return

    todo = set(args.paths)
    if not todo:
        sys.exit("没有给要删除的路径")
    missing = []
    entries = []
    for e in tree["tree"]:
        if e["path"] in todo:
            missing.append(e["path"])
            continue  # 删除 = 不带进新树
        # 保留原始 mode/type（目录是 040000/tree，必须原样带上）
        ent = {"path": e["path"], "mode": e["mode"], "type": e["type"], "sha": e["sha"]}
        entries.append(ent)
    not_found = todo - set(missing)
    if not_found:
        print(f"仓库里不存在（跳过）：{sorted(not_found)}")

    new_tree = api("POST", f"/repos/{OWNER}/{REPO}/git/trees", {"tree": entries})
    new_commit = api("POST", f"/repos/{OWNER}/{REPO}/git/commits",
                     {"message": f"chore: 删除误提交文件（{len(missing)} 个）",
                      "tree": new_tree["sha"], "parents": [head]})
    api("PATCH", f"/repos/{OWNER}/{REPO}/git/refs/heads/{BRANCH}",
        {"sha": new_commit["sha"], "force": False})
    print(f"已删除 {len(missing)} 个文件，commit {new_commit['sha'][:10]}")


if __name__ == "__main__":
    main()
