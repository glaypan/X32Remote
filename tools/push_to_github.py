#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
创建 GitHub 远程仓库并推送代码，全程走 REST API。

为什么需要它：
  github.com 网页在本机超时不可达，"新建仓库"这个本该在网页上点的按钮点不了。
  但 api.github.com 是通的，所以用 API 建仓；推送走 git 协议（实测可用）。

用法:
  cd "E:/AI/workbuddy/x32遥控/X32Remote-ios/tools"
  set GITHUB_TOKEN=ghp_xxxxxxxx
  python push_to_github.py --repo X32Remote --public

Token 权限:
  创建公开仓库 → 经典 PAT 勾 public_repo；创建私有仓库 → 勾 repo。
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # 仓库根 = tools/ 的上一级

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def api(method, path, token, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": "Bearer " + token,
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "x32-pusher",
        "Content-Type": "application/json",
    })
    try:
        with OPENER.open(req, timeout=60) as r:
            body = r.read().decode("utf-8")
            return r.status, (json.loads(body) if body.strip() else {})
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            body = json.loads(body)
        except Exception:
            pass
        return e.code, body


def git(*args, cwd=BASE):
    r = subprocess.run(["git"] + list(args), cwd=cwd, capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def main():
    ap = argparse.ArgumentParser(description="创建 GitHub 仓库并推送")
    ap.add_argument("--repo", default="X32Remote", help="仓库名（默认 X32Remote）")
    ap.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""),
                    help="GitHub PAT（默认读 GITHUB_TOKEN）")
    priv = ap.add_mutually_exclusive_group()
    priv.add_argument("--public", action="store_true", help="建公开仓库（推荐，Actions 额度大）")
    priv.add_argument("--private", action="store_true", help="建私有仓库")
    ap.add_argument("--branch", default="main")
    args = ap.parse_args()

    if not args.token:
        sys.exit("缺少 Token。请先: set GITHUB_TOKEN=ghp_xxxx")

    is_private = bool(args.private)
    if not args.public and not args.private:
        print("未指定 --public/--private，默认建【公开仓库】。")
        is_private = False

    # ---------- 0. 检查本地仓库 ----------
    code, out = git("rev-parse", "--is-inside-work-tree")
    if code != 0:
        sys.exit("当前目录不是 git 仓库。请先在工程根目录执行 git init 并提交。")
    code, out = git("rev-parse", "HEAD")
    if code != 0:
        sys.exit("本地还没有任何提交，请先 git add + git commit。")

    # ---------- 1. 确认身份 ----------
    st, me = api("GET", "/user", args.token)
    if st != 200:
        sys.exit("Token 无效或权限不足（HTTP %s）：%s" % (st, me))
    user = me["login"]
    print("已认证: %s" % user)

    # ---------- 2. 建仓（不存在则创建）----------
    st, info = api("GET", "/repos/%s/%s" % (user, args.repo), args.token)
    if st == 200:
        print("仓库已存在，直接复用: %s" % info["html_url"])
        repo_url = info["clone_url"]
    elif st == 404:
        print("仓库不存在，正在创建 ...")
        payload = {
            "name": args.repo,
            "private": is_private,
            "description": "Behringer X32/M32 remote control — iOS app with cloud-built unsigned IPA",
            "has_issues": False,
            "has_wiki": False,
            "auto_init": False,          # 不要自动建 README，否则 push 会冲突
        }
        st, info = api("POST", "/user/repos", args.token, payload)
        if st not in (200, 201):
            extra = ""
            if isinstance(info, dict) and "message" in info:
                extra = info["message"]
            if st == 403:
                extra += "  （Token 缺少建仓权限：公开仓库需 public_repo，私有需 repo）"
            sys.exit("创建仓库失败（HTTP %s）：%s" % (st, extra))
        repo_url = info["clone_url"]
        print("创建成功: %s" % info["html_url"])
    else:
        sys.exit("查询仓库失败（HTTP %s）：%s" % (st, info))

    # ---------- 3. 推送 ----------
    # 推的时候把 token 临时放进 URL —— 不写入 .git/config 的持久配置
    auth_url = repo_url.replace("https://", "https://%s@" % args.token)
    print("\n推送中 ...")
    code, out = git("remote", "set-url", "origin", auth_url)
    if code != 0:
        code, out = git("remote", "add", "origin", auth_url)
        if code != 0:
            sys.exit("配置 remote 失败:\n" + out)

    code, out = git("push", "-u", "origin", "%s:%s" % (args.branch, args.branch))
    # push 的进度信息在 stderr，不打印会显得卡住
    if code != 0:
        print(out)
        sys.exit("推送失败。若提示认证错误，检查 Token 是否为有效值、是否勾了 repo 权限。")
    print(out.strip()[-500:] or "推送完成")

    # ---------- 4. 把 token 从 remote URL 里撤掉 ----------
    git("remote", "set-url", "origin", repo_url)

    print()
    print("=" * 62)
    print("完成")
    print("=" * 62)
    print("  仓库      : %s" % repo_url)
    print("  Actions   : https://api.github.com/repos/%s/%s/actions/runs" % (user, args.repo))
    print()
    print("  推送已触发云端构建。接下来等 4~6 分钟，然后运行:")
    print()
    print("    set GITHUB_TOKEN=你的Token")
    print("    python fetch_ipa.py --repo %s/%s --wait" % (user, args.repo))
    print()
    print("  如果浏览器打不开 github.com，用上面那条 API 地址查看运行记录即可。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
