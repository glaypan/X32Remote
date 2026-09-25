#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
在没有 Mac 的情况下校验 Xcode 工程的结构与语义完整性。

动机:
  曾经的教训 —— 用解析库能「加载成功」只证明语法合法，不证明语义完整。
  实际踩到的坑：target 声明了 packageProductDependencies，XCSwiftPackageProductDependency
  也在，但缺 package 字段、PBXProject.packageReferences 为空、根本没有
  XCLocalSwiftPackageReference 对象 —— 语法全对，Xcode 却报
  "Missing package product 'X32RemoteCore'"。本地完全看不出来，云端编译才炸。

  所以这个脚本检查的是「引用是否闭合、路径是否真的存在、产品名是否真的被声明」。

用法:
  python verify_xcodeproj.py                     # 默认校验 ../X32Remote.xcodeproj
  python verify_xcodeproj.py --project 路径      # 指定工程
退出码: 0 = 全部通过，1 = 有失败项
"""
import argparse
import os
import re
import sys

ID_RE = re.compile(r"\b[A-F0-9]{24}\b")


class Check:
    def __init__(self):
        self.fails = []
        self.passes = 0

    def ok(self, msg):
        self.passes += 1
        print("  [ok]   %s" % msg)

    def fail(self, msg):
        self.fails.append(msg)
        print("  [FAIL] %s" % msg)

    def info(self, msg):
        print("  [info] %s" % msg)


def read_project(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def block(text, oid):
    """
    取某个对象 ID 对应的大括号内部文本（用括号配对，不能用"第一个 };"截断）。

    两个已踩过的坑：
      1. 本工程的 pbxproj 是手写的，缩进不统一（2 Tab / 3 Tab 混用），
         不能写死 '^\\t\\t'，否则漏掉一批对象导致误报断链；
      2. PBXBuildFile / PBXFileReference 是**单行**对象（'= {isa = ...; ...; };'
         全在一行），不能用"以 { 结尾的行"来识别；同时 PBXProject 里有
         attributes = { ... TargetAttributes = { ... } } 这类嵌套块，
         简单的"找下一个 };"会提前截断，必须真正做括号配对。
    """
    m = re.search(r"^[ \t]+" + oid + r"[^\n]*?= \{", text, re.M)
    if not m:
        return None
    i = m.end()
    depth = 1
    j = i
    while j < len(text):
        ch = text[j]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[i:j]
        j += 1
    return None


def norm(body):
    """
    按 ';' 断行，让单行对象也能按行解析。
    单行写法 'isa = X; fileRef = Y;' 里，'fileRef' 前面没有换行，
    不归一化的话 '^\\s*fileRef' 永远匹配不到。
    """
    if body is None:
        return None
    return re.sub(r";[ \t]*", ";\n", body)


def strip_comment(v):
    """去掉值末尾的 /* ... */ 注释（pbxproj 里引用后面常跟名字注释）"""
    return re.sub(r"/\*.*?\*/", "", v, flags=re.S).strip()


def field(body, key):
    body = norm(body)
    if body is None:
        return None
    m = re.search(r"^\s*" + re.escape(key) + r" = ([^;\n]*);", body, re.M)
    return strip_comment(m.group(1)) if m else None


def list_field(body, key):
    """取 key = ( a, b, ); 形式的多行列表"""
    body = norm(body)
    if body is None:
        return []
    m = re.search(r"^\s*" + re.escape(key) + r" = \((.*?)\n\s*\);", body, re.M | re.S)
    if not m:
        return []
    out = []
    for line in m.group(1).split("\n"):
        s = line.strip().rstrip(",")
        if not s:
            continue
        out.append(s.split("/*")[0].strip())
    return out


def unquote(v):
    if v is None:
        return None
    v = v.strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        return v[1:-1]
    return v


def all_objects(text):
    """
    收集 objects = { } 下的**顶层**对象 → {id: isa}。

    必须按括号深度筛选：PBXProject 里有
        TargetAttributes = { A6000001... = { CreatedOnToolsVersion = 15.0; }; };
    这种嵌套块，只看行首正则会把内层 ID 也当顶层对象。
    缩进一律不能写死 —— 本工程里 ChannelsView.swift 那一行是**顶格**的（0 缩进）。
    """
    objs = {}
    depth = 0
    obj_depth = None          # objects = { 所在层级（不能写死，文件最外层还包着一层 { }）
    pat = re.compile(r"^[ \t]*([A-F0-9]{24})[^\n]*?= \{")
    for line in text.split("\n"):
        if obj_depth is not None and depth == obj_depth:
            m = pat.match(line)
            if m:
                objs[m.group(1)] = None
        depth += line.count("{") - line.count("}")
        if obj_depth is None and re.match(r"^[ \t]*objects = \{", line):
            obj_depth = depth
    for oid in list(objs):
        objs[oid] = field(block(text, oid), "isa")
    return objs


def group_resolver(text, objs):
    """返回 full_path(oid) —— 把 PBXGroup 树拼成相对工程目录的路径"""
    parent, gname = {}, {}
    for oid, isa in objs.items():
        if isa != "PBXGroup":
            continue
        b = block(text, oid)
        gname[oid] = unquote(field(b, "path")) or unquote(field(b, "name")) or ""
        for ch in list_field(b, "children"):
            parent[ch] = oid

    def full(oid):
        parts, cur, seen = [], oid, set()
        while cur in parent and cur not in seen:
            seen.add(cur)
            p = parent[cur]
            parts.append(gname.get(p, ""))
            cur = p
        return os.path.join(*[p for p in reversed(parts) if p]) if parts else ""

    return full


def package_products(pkg_swift):
    """从 Package.swift 里取出 .library(name:) 声明的产品名"""
    try:
        with open(pkg_swift, "r", encoding="utf-8", errors="replace") as f:
            txt = f.read()
    except OSError:
        return []
    return re.findall(r"\.library\(\s*name:\s*\"([^\"]+)\"", txt)


def main():
    ap = argparse.ArgumentParser(description="校验 Xcode 工程结构与语义完整性")
    here = os.path.dirname(os.path.abspath(__file__))
    default_proj = os.path.normpath(os.path.join(here, "..", "X32Remote.xcodeproj"))
    ap.add_argument("--project", default=default_proj, help="Xcode 工程路径")
    args = ap.parse_args()

    proj_dir = os.path.abspath(args.project)
    proj_parent = os.path.dirname(proj_dir)          # .xcodeproj 所在目录
    pbx = os.path.join(proj_dir, "project.pbxproj")
    if not os.path.isfile(pbx):
        sys.exit("找不到 project.pbxproj: %s" % pbx)

    text = read_project(pbx)
    c = Check()

    print("工程: %s" % proj_dir)
    print("=" * 62)

    # ---------- 1. 格式版本 ----------
    print("\n[1] 工程格式")
    m = re.search(r"objectVersion = (\d+);", text)
    if m:
        c.info("objectVersion = %s" % m.group(1))
    m = re.search(r"compatibilityVersion = \"([^\"]+)\";", text)
    if m:
        c.info("compatibilityVersion = %s" % m.group(1))

    # ---------- 2. ID 长度统一 ----------
    print("\n[2] 对象 ID")
    lengths = {}
    for tok in ID_RE.findall(text):
        lengths[len(tok)] = lengths.get(len(tok), 0) + 1
    c.info("长度分布: %s" % lengths)
    if set(lengths) == {24}:
        c.ok("所有 ID 均为 24 位十六进制")
    else:
        c.fail("存在非 24 位 ID: %s（Xcode 只生成 24 位）" % sorted(lengths))

    # ---------- 3. 引用闭合 ----------
    print("\n[3] 引用闭合性")
    objs = all_objects(text)
    defined = set(objs)
    referenced = set(ID_RE.findall(text))
    dangling = sorted(referenced - defined)
    if dangling:
        c.fail("有 %d 个引用指向不存在的对象: %s" % (len(dangling), dangling[:8]))
    else:
        c.ok("所有 %d 个引用都能找到定义（共 %d 个对象）" % (len(referenced), len(defined)))

    # ---------- 4. SPM 包引用（本次踩坑点）----------
    print("\n[4] Swift Package 依赖完整性")
    proj_oid = None
    m = re.search(r"rootObject = ([A-F0-9]{24})", text)
    if m:
        proj_oid = m.group(1)
    proj_body = block(text, proj_oid) if proj_oid else None

    pkg_refs = list_field(proj_body, "packageReferences")
    local_refs = [o for o, isa in objs.items() if isa == "XCLocalSwiftPackageReference"]
    remote_refs = [o for o, isa in objs.items() if isa == "XCRemoteSwiftPackageReference"]
    prod_deps = [o for o, isa in objs.items() if isa == "XCSwiftPackageProductDependency"]

    c.info("packageReferences=%d  本地包=%d  远程包=%d  产品依赖=%d"
           % (len(pkg_refs), len(local_refs), len(remote_refs), len(prod_deps)))

    for r in pkg_refs:
        if r not in defined:
            c.fail("packageReferences 里的 %s 未定义" % r)
    if not dangling:
        pass

    # 4a. 每个产品依赖必须指明来自哪个包
    provided = {}
    for oid in local_refs:
        body = block(text, oid)
        rel = unquote(field(body, "relativePath"))
        abspath = os.path.normpath(os.path.join(proj_parent, rel or ""))
        manifest = os.path.join(abspath, "Package.swift")
        exists = os.path.isfile(manifest)
        prods = package_products(manifest) if exists else []
        provided[oid] = prods
        if not exists:
            c.fail("本地包 %s: relativePath=%r 处没有 Package.swift（解析为 %s）"
                   % (oid, rel, abspath))
        else:
            c.ok("本地包 relativePath=%r → 找到 Package.swift，产品: %s"
                 % (rel, prods or "(未解析到 .library)"))
            # 包引用是否被工程登记
            if oid not in pkg_refs:
                c.fail("本地包 %s 未登记到 PBXProject.packageReferences" % oid)

    if prod_deps and not (local_refs or remote_refs):
        c.fail("存在产品依赖但工程里没有任何包引用 —— Xcode 会报 "
               "\"Missing package product\"。需补 XCLocalSwiftPackageReference")

    used_products = []
    for oid in prod_deps:
        body = block(text, oid)
        pname = unquote(field(body, "productName"))
        pkg = field(body, "package")
        used_products.append(pname)
        if not pkg:
            c.fail("产品依赖 %s (productName=%s) 缺少 package 字段 → 不指明来自哪个包，"
                   "Xcode 报 Missing package product" % (oid, pname))
            continue
        if pkg not in defined:
            c.fail("产品依赖 %s 的 package=%s 未定义" % (oid, pkg))
            continue
        if pkg in provided and provided[pkg] and pname not in provided[pkg]:
            c.fail("产品 %r 不在包声明的产品列表 %s 中" % (pname, provided[pkg]))
        else:
            c.ok("产品依赖 %s → package %s，productName=%s" % (oid, pkg, pname))

    # 4b. 目标是否真的把这个产品挂上
    for oid, isa in objs.items():
        if isa != "PBXNativeTarget":
            continue
        body = block(text, oid)
        deps = list_field(body, "packageProductDependencies")
        for d in deps:
            if d not in defined:
                c.fail("target %s 的 packageProductDependencies 含未定义对象 %s" % (oid, d))
            else:
                c.ok("target %s 依赖产品 %s" % (oid, d))
        # 每个依赖产品都应在 Frameworks 阶段被链接
        phases = list_field(body, "buildPhases")
        linked = set()
        for p in phases:
            pb = block(text, p)
            if field(pb, "isa") == "PBXFrameworksBuildPhase":
                for f in list_field(pb, "files"):
                    fb = block(text, f)
                    pr = field(fb, "productRef")
                    if pr:
                        linked.add(pr)
        for d in deps:
            if d in linked:
                c.ok("产品 %s 已在 Frameworks 阶段链接" % d)
            else:
                c.fail("产品 %s 被声明依赖但未在 Frameworks 阶段链接" % d)

    # ---------- 5. 构建文件引用 ----------
    print("\n[5] 构建文件引用")
    missing = []
    checked = 0
    for oid, isa in objs.items():
        if isa != "PBXBuildFile":
            continue
        body = block(text, oid)
        for key in ("fileRef", "productRef"):
            t = field(body, key)
            if t:
                checked += 1
                if t not in defined:
                    missing.append("%s.%s=%s" % (oid, key, t))
    if missing:
        c.fail("PBXBuildFile 有 %d 处悬空引用: %s" % (len(missing), missing[:6]))
    else:
        c.ok("%d 个 PBXBuildFile 引用全部有效" % checked)

    # ---------- 6. 磁盘文件是否存在 ----------
    print("\n[6] 源文件 / 资源文件存在性")
    full_path = group_resolver(text, objs)
    absent, n = [], 0
    for oid, isa in objs.items():
        if isa != "PBXFileReference":
            continue
        b = block(text, oid)
        p = unquote(field(b, "path"))
        src = unquote(field(b, "sourceTree"))
        if not p or src != "<group>":
            continue          # 构建产物等（BUILT_PRODUCTS_DIR）不在磁盘上
        rel = os.path.join(full_path(oid), p)
        n += 1
        if not os.path.exists(os.path.normpath(os.path.join(proj_parent, rel))):
            absent.append(rel)
    if absent:
        c.fail("有 %d 个文件引用在磁盘上不存在: %s" % (len(absent), absent[:6]))
    else:
        c.ok("%d 个文件引用在磁盘上都能找到（已按 PBXGroup 层级解析路径）" % n)

    # ---------- 7. scheme 指向真实 target ----------
    print("\n[7] 共享 scheme")
    scheme = os.path.join(proj_dir, "xcshareddata", "xcschemes", "X32Remote.xcscheme")
    if not os.path.isfile(scheme):
        c.fail("缺少共享 scheme: %s（xcodebuild -scheme 会失败）" % scheme)
    else:
        stext = read_project(scheme)
        ids = set(re.findall(r'BlueprintIdentifier = "([^"]+)"', stext))
        bad = [i for i in ids if i not in defined]
        if bad:
            c.fail("scheme 指向不存在的 target: %s" % bad)
        else:
            c.ok("scheme 的 BlueprintIdentifier %s 均指向真实 target" % sorted(ids))

    # ---------- 8. 括号平衡 ----------
    print("\n[8] 括号平衡")
    for op, cl, name in (("{", "}", "花括号"), ("(", ")", "圆括号")):
        if text.count(op) != text.count(cl):
            c.fail("%s不平衡: %d 个 %s vs %d 个 %s"
                   % (name, text.count(op), op, text.count(cl), cl))
        else:
            c.ok("%s平衡 (%d 对)" % (name, text.count(op)))

    # ---------- 汇总 ----------
    print()
    print("=" * 62)
    if c.fails:
        print("结果: %d 项通过, %d 项失败" % (c.passes, len(c.fails)))
        for f in c.fails:
            print("  FAIL: %s" % f)
        return 1
    print("结果: 全部通过（%d 项）" % c.passes)
    return 0


if __name__ == "__main__":
    sys.exit(main())
