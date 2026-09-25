#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 GitHub Actions 下载最新构建的无签名 IPA。

为什么要单独写这个脚本：
  github.com 的网页端在部分网络环境下不可达（本机实测 22s 超时），
  但 api.github.com / objects.githubusercontent.com 是通的。
  所以整个「查看构建状态 → 下载产物」流程全部走 REST API，不碰网页。

用法:
  set GITHUB_TOKEN=ghp_xxxxxxxx
  python fetch_ipa.py --repo 你的用户名/X32Remote
  python fetch_ipa.py --repo 你的用户名/X32Remote --status     # 只看状态
  python fetch_ipa.py --repo 你的用户名/X32Remote --wait       # 等构建跑完再下

Token 权限:
  经典 PAT 勾选 repo（私有仓库）或 public_repo；细粒度 PAT 需要 Actions: Read。
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
import zipfile

API = "https://api.github.com"
ARTIFACT_NAME = "X32Remote-unsigned-ipa"


class _DropAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    """下载 artifact 会 302 跳到对象存储，那里用的是预签名 URL，不能带 Authorization。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            for h in ("Authorization", "authorization"):
                new.headers.pop(h, None)
            new.unredirected_hdrs.pop("Authorization", None)
            new.unredirected_hdrs.pop("authorization", None)
        return new


OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),       # 本地/直连不走代理
    _DropAuthOnRedirect(),
)


def api(path, token, raw=False):
    req = urllib.request.Request(API + path, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": "Bearer " + token,
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "x32-ipa-fetcher",
    })
    try:
        resp = OPENER.open(req, timeout=60)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:300]
        if e.code == 401:
            sys.exit("鉴权失败(401)：Token 无效或已过期。")
        if e.code == 404:
            sys.exit("找不到仓库(404)：检查 --repo 拼写，以及 Token 是否有该仓库权限。")
        sys.exit("GitHub API 错误 %d: %s" % (e.code, body))
    data = resp.read()
    return data if raw else json.loads(data.decode("utf-8"))


def latest_run(repo, token, branch=None):
    q = "/repos/%s/actions/runs?per_page=10" % repo
    if branch:
        q += "&branch=" + branch
    runs = api(q, token).get("workflow_runs", [])
    if not runs:
        sys.exit("该仓库还没有任何 Actions 运行记录 —— 确认 workflow 已推送且至少触发过一次。")
    return runs[0]


def show_status(run):
    s = run.get("status")          # queued / in_progress / completed
    c = run.get("conclusion")      # success / failure / cancelled / None
    name = run.get("name") or run.get("display_title", "")
    print("  工作流   : %s" % name)
    print("  分支     : %s" % run.get("head_branch"))
    print("  提交     : %s" % (run.get("head_sha") or "")[:8])
    print("  状态     : %s%s" % (s, (" / " + c) if c else ""))
    print("  开始时间 : %s" % run.get("created_at"))
    print("  页面     : %s" % run.get("html_url"))
    return s, c


def pushable():
    """按空格划分的日志兼容打印"""
    print()


def wait_for(run, repo, token, timeout=1800):
    """轮询直到构建结束"""
    t0 = time.time()
    seen = None
    while time.time() - t0 < timeout:
        run = api("/repos/%s/actions/runs/%d" % (repo, run["id"]), token)
        s = run.get("status")
        if s != seen:
            print("    [%5.0fs] 状态: %s" % (time.time() - t0, s))
            seen = s
        if s == "completed":
            return run
        time.sleep(10)
    sys.exit("等待超时（%d 秒），构建仍未结束。" % timeout)


def pick_artifact(repo, token, run_id):
    arts = api("/repos/%s/actions/runs/%d/artifacts" % (repo, run_id), token).get("artifacts", [])
    if not arts:
        sys.exit("该次运行没有产物 —— 多半是编译失败，去日志里看报错。")
    exact = [a for a in arts if a["name"] == ARTIFACT_NAME]
    cand = exact or arts
    cand.sort(key=lambda a: a.get("created_at", ""), reverse=True)
    return cand[0]


def download(repo, token, artifact, out_dir):
    aid = artifact["id"]
    url = "%s/repos/%s/actions/artifacts/%d/zip" % (API, repo, aid)
    os.makedirs(out_dir, exist_ok=True)
    zip_path = os.path.join(out_dir, artifact["name"] + ".zip")

    print("  下载中: %s (%.2f MB)" % (artifact["name"], (artifact.get("size_in_bytes") or 0) / 1048576))
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": "Bearer " + token,
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "x32-ipa-fetcher",
    })
    with OPENER.open(req, timeout=600) as r, open(zip_path, "wb") as f:
        while True:
            chunk = r.read(65536)
            if not chunk:
                break
            f.write(chunk)
    print("  已保存: %s (%.2f MB)" % (zip_path, os.path.getsize(zip_path) / 1048576))

    # 解包，取出 .ipa
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(out_dir)
    ipa = None
    for root, _dirs, files in os.walk(out_dir):
        for fn in files:
            if fn.lower().endswith(".ipa"):
                ipa = os.path.join(root, fn)
                break
        if ipa:
            break
    if not ipa:
        sys.exit("解包后没找到 .ipa，检查 artifact 内容: %s" % out_dir)
    ipa_final = os.path.join(out_dir, "X32Remote-unsigned.ipa")
    if os.path.abspath(ipa) != os.path.abspath(ipa_final):
        os.replace(ipa, ipa_final)
    print()
    print("  ✅ IPA 就绪: %s" % ipa_final)
    print("     下一步: 用 Sideloadly 把这个 ipa 拖进去，选你的 Apple ID 签名安装。")
    return ipa_final


def main():
    ap = argparse.ArgumentParser(description="下载 GitHub Actions 构建的无签名 IPA")
    ap.add_argument("--repo", required=True, help="owner/仓库名，例如 zhangsan/X32Remote")
    ap.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""),
                    help="GitHub PAT（默认读环境变量 GITHUB_TOKEN）")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "outputs"),
                    help="IPA 输出目录（默认项目 outputs/）")
    ap.add_argument("--status", action="store_true", help="只显示最新构建状态，不下载")
    ap.add_argument("--wait", action="store_true", help="若正在构建，则轮询等待完成")
    args = ap.parse_args()

    if not args.token:
        sys.exit("缺少 Token。请先: set GITHUB_TOKEN=ghp_xxxx  或加 --token 参数。")

    print("=" * 60)
    print("仓库: %s" % args.repo)
    print("=" * 60)

    run = latest_run(args.repo, args.token)
    print("\n最新一次运行:")
    status, conclusion = show_status(run)

    if args.status:
        return 0

    if status != "completed":
        if not args.wait:
            sys.exit("\n构建尚未完成（当前 %s）。加 --wait 可等它跑完，或稍后重试。" % status)
        print("\n等待构建完成 ...")
        run = wait_for(run, args.repo, args.token)
        print("\n最终状态:")
        _s, conclusion = show_status(run)

    if conclusion != "success":
        sys.exit("\n构建未成功（%s）。用浏览器或 API 查看日志: %s" % (conclusion, run.get("html_url")))

    print("\n产物:")
    art = pick_artifact(args.repo, args.token, run["id"])
    out_dir = os.path.abspath(args.out)
    download(args.repo, args.token, art, out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
