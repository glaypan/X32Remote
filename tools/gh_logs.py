#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
查看 GitHub Actions 运行详情与失败日志，全程走 REST API。

为什么需要它:
  github.com 网页在本机超时不可达，看不到 Actions 的日志页面。
  但 api.github.com 通，用它拿 job/step 结论 + 下载日志 zip。

用法:
  set GITHUB_TOKEN=ghp_xxxxxxxx
  python gh_logs.py --repo glaypan/X32Remote              # 最新一次:各步骤结论 + 失败日志尾部
  python gh_logs.py --repo glaypan/X32Remote --run-id 123 # 指定某次运行
  python gh_logs.py --repo glaypan/X32Remote --tail 80    # 多看几行
  python gh_logs.py --repo glaypan/X32Remote --steps      # 只看步骤结论,不拉日志

Token 权限: 经典 PAT 勾 repo（或 public_repo）；细粒度 PAT 需要 Actions: Read。
"""
import argparse
import io
import json
import os
import sys
import urllib.error
import urllib.request
import zipfile

API = "https://api.github.com"


class _DropAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    """日志 zip 会 302 跳到对象存储，那里用预签名 URL，不能带 Authorization。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            for h in list(new.headers.keys()):
                if h.lower() == "authorization":
                    del new.headers[h]
            new.unredirected_hdrs.pop("Authorization", None)
            new.unredirected_hdrs.pop("authorization", None)
        return new


OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}), _DropAuthOnRedirect())


def api(path, token, raw=False):
    req = urllib.request.Request(API + path, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": "Bearer " + token,
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "x32-logs",
    })
    try:
        resp = OPENER.open(req, timeout=120)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:300]
        if e.code == 401:
            sys.exit("鉴权失败(401)：Token 无效或已过期。")
        if e.code == 404:
            sys.exit("找不到(404)：检查 --repo 拼写与 Token 权限。")
        sys.exit("GitHub API 错误 %d: %s" % (e.code, body))
    data = resp.read()
    return data if raw else json.loads(data.decode("utf-8"))


def print_jobs(repo, token, run_id):
    """
    打印每个 job 的每个 step 及结论。
    返回 {job 名: {失败的 step 名}}，供后续精确挑出失败步骤的日志文件。
    """
    jobs = api("/repos/%s/actions/runs/%d/jobs" % (repo, run_id), token).get("jobs", [])
    failed = {}
    for j in jobs:
        mark = {"success": "OK  ", "failure": "FAIL", "skipped": "SKIP",
                "cancelled": "CANC", None: "----"}.get(j.get("conclusion"), "????")
        print("  [%s] %s  (%s)" % (mark, j.get("name"), j.get("conclusion")))
        bad = set()
        for s in j.get("steps", []):
            sc = s.get("conclusion")
            icon = {"success": "  ok  ", "failure": "  FAIL", "skipped": "  skip",
                    "cancelled": "  canc", None: "  --  "}.get(sc, "  ??  ")
            print("        %s %s" % (icon, s.get("name")))
            if sc == "failure":
                bad.add(s.get("name"))
        if bad:
            failed[j.get("name")] = bad
    return failed


def step_of(member):
    """从 zip 成员名 '<job>/<序号>_<步骤名>.txt' 里取出步骤名"""
    base = member.split("/")[-1]
    if base.endswith(".txt"):
        base = base[:-4]
    if "_" in base:
        base = base.split("_", 1)[1]
    return base


def fetch_logs(repo, token, run_id):
    """下载日志 zip，返回 {成员名: 文本}"""
    data = api("/repos/%s/actions/runs/%d/logs" % (repo, run_id), token, raw=True)
    out = {}
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for n in z.namelist():
            if n.endswith("/"):
                continue
            try:
                out[n] = z.read(n).decode("utf-8", "replace")
            except Exception as e:
                out[n] = "(读取失败: %s)" % e
    return out


def tail(text, n):
    lines = text.splitlines()
    if len(lines) <= n:
        return "\n".join(lines)
    return "... (省略前 %d 行)\n" % (len(lines) - n) + "\n".join(lines[-n:])


def main():
    ap = argparse.ArgumentParser(description="查看 GitHub Actions 运行与失败日志")
    ap.add_argument("--repo", required=True, help="owner/repo")
    ap.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""),
                    help="GitHub PAT（默认读 GITHUB_TOKEN）")
    ap.add_argument("--run-id", type=int, default=0, help="指定运行 id（默认最新一次）")
    ap.add_argument("--steps", action="store_true", help="只看步骤结论，不下载日志")
    ap.add_argument("--tail", type=int, default=60, help="每个失败步骤打印的日志行数")
    args = ap.parse_args()

    if not args.token:
        sys.exit("缺少 Token。请先: set GITHUB_TOKEN=ghp_xxxx")

    repo = args.repo
    run_id = args.run_id
    if not run_id:
        runs = api("/repos/%s/actions/runs?per_page=1" % repo, args.token).get("workflow_runs", [])
        if not runs:
            sys.exit("该仓库没有任何运行记录。")
        run_id = runs[0]["id"]
        print("仓库 %s" % repo)
        print("运行 #%d  提交 %s  状态 %s / %s" % (
            run_id, (runs[0].get("head_sha") or "")[:8],
            runs[0].get("status"), runs[0].get("conclusion")))
        print("页面 %s" % runs[0].get("html_url"))
        print()

    print("=" * 62)
    print("步骤结论")
    print("=" * 62)
    failed = print_jobs(repo, args.token, run_id)

    if args.steps or not failed:
        if not failed:
            print("\n没有失败的 job。")
        return 0

    print()
    print("=" * 62)
    print("失败步骤日志（最后 %d 行）" % args.tail)
    print("=" * 62)
    logs = fetch_logs(repo, args.token, run_id)
    if not logs:
        print("(日志为空或已过期)")
        return 1

    # 日志 zip 结构: <job 名>/<序号>_<步骤名>.txt —— 只挑真正失败的步骤
    showed = 0
    for name in sorted(logs):
        parts = name.split("/")
        if len(parts) < 2:
            continue
        job = parts[0]
        if job not in failed:
            continue
        if step_of(name) not in failed[job]:
            continue
        print()
        print("--- %s ---" % name)
        print(tail(logs[name], args.tail))
        showed += 1

    if not showed:
        print("(未匹配到失败步骤的日志文件；zip 内实际成员：)")
        for n in sorted(logs)[:40]:
            print("   ", n)
    return 1


if __name__ == "__main__":
    sys.exit(main())
