#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
iOS 端到端一条命令：建仓 → 推送 → 等云端编译 → 下载 IPA。

把 push_to_github.py 和 fetch_ipa.py 串起来，省得记两条命令。
全程走 api.github.com（github.com 网页在你的网络下打不开）。

用法:
  cd "E:/AI/workbuddy/x32遥控/X32Remote-ios/tools"
  set GITHUB_TOKEN=ghp_xxxxxxxx
  python ios_build.py

  python ios_build.py --skip-push      # 已经推送过，只等构建 + 下载
  python ios_build.py --status         # 只看当前构建状态

拿到 outputs/X32Remote-unsigned.ipa 后，用 Sideloadly 签名安装。
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
API = "https://api.github.com"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def api(path, token):
    req = urllib.request.Request(API + path, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": "Bearer " + token,
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "x32-ios-build",
    })
    try:
        with OPENER.open(req, timeout=60) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:300]
        sys.exit("API 出错 %d: %s" % (e.code, body))


def step(n, total, title):
    print()
    print("=" * 62)
    print("  [%d/%d] %s" % (n, total, title))
    print("=" * 62)


def call(script, args, token):
    """调用同目录下的兄弟脚本，token 走环境变量而不是命令行（避免出现在进程列表）"""
    env = dict(os.environ)
    env["GITHUB_TOKEN"] = token
    r = subprocess.run([PY, os.path.join(HERE, script)] + args, cwd=HERE, env=env)
    return r.returncode


def main():
    ap = argparse.ArgumentParser(description="iOS 一条命令完成构建与下载")
    ap.add_argument("--repo", default="X32Remote", help="仓库名（默认 X32Remote）")
    ap.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""),
                    help="GitHub PAT（默认读 GITHUB_TOKEN）")
    ap.add_argument("--private", action="store_true", help="建私有仓库（默认公开）")
    ap.add_argument("--skip-push", action="store_true", help="跳过建仓与推送")
    ap.add_argument("--status", action="store_true", help="只看状态，不做任何事")
    args = ap.parse_args()

    if not args.token:
        sys.exit("缺少 Token。请先: set GITHUB_TOKEN=ghp_xxxx\n"
                 "（在 GitHub → Settings → Developer settings → Personal access tokens 生成，\n"
                 " 经典 Token 需同时勾选 public_repo（或 repo）+ workflow）")

    me = api("/user", args.token)
    owner = me["login"]
    full = "%s/%s" % (owner, args.repo)
    print("GitHub 身份: %s" % owner)

    if args.status:
        step(1, 1, "查询构建状态")
        return call("fetch_ipa.py", ["--repo", full, "--status"], args.token)

    total = 2 if args.skip_push else 3

    if not args.skip_push:
        step(1, total, "建仓并推送代码")
        pa = ["--repo", args.repo, "--token", args.token]
        pa += ["--private"] if args.private else ["--public"]
        if call("push_to_github.py", pa, args.token) != 0:
            sys.exit("\n推送失败，已中止。修好上面的报错后重跑本脚本即可（仓库若已建好会用 --skip-push）。")
    else:
        print("已跳过推送。")

    step(2 if not args.skip_push else 1, total, "等待云端编译并下载 IPA")
    print("（首次构建约 4~6 分钟，脚本会一直轮询到结束）")
    rc = call("fetch_ipa.py", ["--repo", full, "--token", args.token, "--wait"], args.token)
    if rc != 0:
        print("\n下载未成功。可以先用下面这条看状态：")
        print("  python ios_build.py --skip-push --status")
        return rc

    step(3 if not args.skip_push else 2, total, "完成")
    print("IPA 已就绪，下一步：用 Sideloadly 打开它，填 Apple ID 签名安装。")
    print("详细步骤见项目根目录的《iOS-真机直装指南.md》第六节。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
