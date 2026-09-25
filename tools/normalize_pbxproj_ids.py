#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 project.pbxproj 里的对象 ID 统一规范成 Xcode 标准的 24 位十六进制。

背景：
  本工程原有的 pbxproj 是手工编写的，对象 ID 长度不一致（23 位与 24 位混用）。
  Xcode 自己生成的 ID 恒为 24 位；非标准的 23 位 ID 在部分 Xcode/xcodebuild
  版本上可能被判为「工程已损坏」，导致云端构建直接失败。

做法：
  对每个 23 位 ID 末尾补一个 '0' 变成 24 位。补位前后都会做冲突检查，
  替换使用带边界的正则，确保只命中完整的 ID 而不误伤子串。

用法:
  python normalize_pbxproj_ids.py            # 实际修改
  python normalize_pbxproj_ids.py --dry-run  # 只报告，不改动
"""
import argparse
import collections
import os
import re
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(BASE, "X32Remote.xcodeproj", "project.pbxproj")

# 前后都不能紧邻十六进制字符，保证匹配到的是完整 ID 而不是某个 ID 的前缀
TOKEN = re.compile(r"(?<![A-Fa-f0-9])([A-Fa-f0-9]{16,30})(?![A-Fa-f0-9])")

TARGET_LEN = 24


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="只报告差异，不写文件")
    args = ap.parse_args()

    if not os.path.isfile(PBXPROJ):
        sys.exit("找不到 %s" % PBXPROJ)

    with open(PBXPROJ, encoding="utf-8", newline="") as f:
        src = f.read()

    tokens = set(TOKEN.findall(src))
    before = collections.Counter(len(t) for t in tokens)
    print("规范前长度分布: %s" % dict(sorted(before.items())))

    if before.get(TARGET_LEN, 0) == len(tokens):
        print("所有 ID 均为 %d 位，无需处理。" % TARGET_LEN)
        return 0

    existing = {t for t in tokens if len(t) == TARGET_LEN}

    # 构造映射：短的全部补 '0' 到目标长度
    mapping = {}
    for t in tokens:
        if len(t) < TARGET_LEN:
            mapping[t] = t + "0" * (TARGET_LEN - len(t))
        elif len(t) > TARGET_LEN:
            sys.exit("发现超长 ID（%d 位）：%s —— 本脚本不处理，需人工确认。" % (len(t), t))

    # 冲突检查 1：新 ID 不能撞上已存在的标准 ID
    clash = {o: n for o, n in mapping.items() if n in existing}
    if clash:
        print("冲突：补位后会与已有 ID 重复")
        for o, n in list(clash.items())[:5]:
            print("  %s -> %s" % (o, n))
        return 1

    # 冲突检查 2：映射结果之间不能互相重复
    if len(set(mapping.values())) != len(mapping):
        print("冲突：补位结果之间存在重复")
        return 1

    # 冲突检查 3：新 ID 不能是别的 ID 的前缀（避免边界匹配误伤）
    all_after = existing | set(mapping.values())
    for a in all_after:
        for b in all_after:
            if a != b and b.startswith(a):
                print("冲突：%s 是 %s 的前缀" % (a, b))
                return 1

    print("待修正 %d 个 ID（例如 %s -> %s）" % (
        len(mapping),
        sorted(mapping)[0],
        mapping[sorted(mapping)[0]],
    ))

    def repl(m):
        tok = m.group(1)
        return mapping.get(tok, tok)

    out = TOKEN.sub(repl, src)

    # 校验结果
    after_tokens = set(TOKEN.findall(out))
    after = collections.Counter(len(t) for t in after_tokens)
    print("规范后长度分布: %s" % dict(sorted(after.items())))
    if set(after.keys()) != {TARGET_LEN}:
        print("校验失败：仍存在非 %d 位 ID" % TARGET_LEN)
        return 1

    # 引用完整性：替换不应改变结构字符
    if out.count("{") != src.count("{") or out.count("}") != src.count("}"):
        print("校验失败：花括号数量发生变化")
        return 1

    if args.dry_run:
        print("\n[dry-run] 未写入文件。")
        return 0

    with open(PBXPROJ, "w", encoding="utf-8", newline="") as f:
        f.write(out)
    print("\n已写入 %s" % PBXPROJ)
    return 0


if __name__ == "__main__":
    sys.exit(main())
