#!/usr/bin/env bash
# 无 Mac 环境下对 X32RemoteCore 的深度校验（Windows 版）
#
#   [1/4] swiftc -parse          语法
#   [2/4] swiftc -typecheck      类型（核心库 + Network.framework 桩）
#   [3/4] swiftc -emit-module    完整语义
#   [4/4] swiftc -typecheck      测试代码（依赖 [3] 产出的 .swiftmodule）
#
# 为什么需要 [3]: -emit-module 比 -typecheck 更严格,能捕获 "return from
# initializer without initializing all stored properties" 这类 -typecheck 漏报的问题。
# 为什么需要 [4]: 测试代码用 @testable import,必须先用 -I 指向产出的 .swiftmodule。
#
# 前置: 装好 Swift for Windows（官方 WiX 安装器静默安装即可）,路径见下方自动探测。
# 用法: bash tools/local_verify.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(dirname "$HERE")"
WORK="${WORK:-$PROJ/.localverify}"

# ---------- 探测工具链 ----------
# 注意: Toolchains/<ver> 与 Platforms/<ver> 的命名不一定相同
# （官方安装器常见 Toolchains/6.3.3+Asserts 配 Platforms/6.3.3），故分别探测。
SWIFT_ROOT="${SWIFT_ROOT:-$LOCALAPPDATA/Programs/Swift}"
TOOLCHAIN_VER=$(ls "$SWIFT_ROOT/Toolchains" 2>/dev/null | head -1)
PLAT_VER=$(ls "$SWIFT_ROOT/Platforms" 2>/dev/null | head -1)
if [ -z "$TOOLCHAIN_VER" ] || [ -z "$PLAT_VER" ]; then
  echo "找不到 Swift 工具链。请设置 SWIFT_ROOT 指向 Swift 安装根目录（内含 Toolchains/ 与 Platforms/）。" >&2
  exit 2
fi
SWIFTC="$SWIFT_ROOT/Toolchains/$TOOLCHAIN_VER/usr/bin/swiftc.exe"
SDK="$SWIFT_ROOT/Platforms/$PLAT_VER/Windows.platform/Developer/SDKs/Windows.sdk"
XCTEST="$SWIFT_ROOT/Platforms/$PLAT_VER/Windows.platform/Developer/Library/XCTest-$PLAT_VER/usr/lib/swift/windows"

for p in "$SWIFTC" "$SDK"; do
  [ -e "$p" ] || { echo "缺少: $p" >&2; exit 2; }
done

# 环境里大小写重复的 http_proxy/https_proxy 会让 swift 前端崩溃
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null

FAIL=0
step() { echo; echo "==================== $* ===================="; }

# ---------- 准备干净工作区 ----------
rm -rf "$WORK"
mkdir -p "$WORK/src" "$WORK/tests"

(cd "$PROJ/Sources/X32RemoteCore" && find . -name '*.swift' | grep -v 'Network/X32Client.swift') > "$WORK/filelist.txt"
while read -r f; do
  mkdir -p "$WORK/src/$(dirname "$f")"
  cp "$PROJ/Sources/X32RemoteCore/$f" "$WORK/src/$f"
done < "$WORK/filelist.txt"
cp "$PROJ"/Tests/X32RemoteCoreTests/*.swift "$WORK/tests/" 2>/dev/null

echo "核心文件: $(cd "$WORK/src" && find . -name '*.swift' | wc -l)  测试文件: $(cd "$WORK/tests" && find . -name '*.swift' | wc -l)"

# ---------- 1) 语法 ----------
step "1/4 swiftc -parse（语法）"
(cd "$WORK/src" && "$SWIFTC" -parse -sdk "$SDK" $(find . -name '*.swift') 2>&1) | tee "$WORK/parse.log"
if grep -qE 'error:' "$WORK/parse.log"; then echo ">>> PARSE FAILED"; FAIL=1; else echo ">>> parse OK"; fi

# ---------- 桩 ----------
step "生成 Network.framework 桩"
python "$HERE/network_stub.py" "$WORK/src/Network/X32Client.swift" || FAIL=1

# ---------- 2) 类型检查 ----------
step "2/4 swiftc -typecheck（核心库）"
(cd "$WORK/src" && "$SWIFTC" -typecheck -sdk "$SDK" -I "$XCTEST" $(find . -name '*.swift') 2>&1) | tee "$WORK/typecheck.log"
if grep -qE 'error:' "$WORK/typecheck.log"; then echo ">>> TYPECHECK FAILED"; FAIL=1; else echo ">>> typecheck OK"; fi

# ---------- 3) 完整语义 ----------
step "3/4 swiftc -emit-module -enable-testing（完整语义）"
(cd "$WORK/src" && "$SWIFTC" -emit-module -enable-testing -module-name X32RemoteCore \
   -emit-module-path "$WORK/X32RemoteCore.swiftmodule" -sdk "$SDK" -I "$XCTEST" \
   $(find . -name '*.swift') 2>&1) | tee "$WORK/emit.log"
if grep -qE 'error:' "$WORK/emit.log"; then echo ">>> EMIT FAILED"; FAIL=1; else echo ">>> emit OK"; ls -l "$WORK/X32RemoteCore.swiftmodule"; fi

# ---------- 4) 测试代码 ----------
step "4/4 swiftc -typecheck（测试代码）"
(cd "$WORK" && "$SWIFTC" -typecheck -sdk "$SDK" -I "$XCTEST" -I "$WORK" \
   $(find src -name '*.swift') $(find tests -name '*.swift') 2>&1) | tee "$WORK/typecheck_tests.log"
if grep -qE 'error:' "$WORK/typecheck_tests.log"; then echo ">>> TEST TYPECHECK FAILED"; FAIL=1; else echo ">>> test typecheck OK"; fi

echo
if [ "$FAIL" -eq 0 ]; then echo "==== 全部通过 ===="; else echo "==== 存在失败 ===="; fi
exit "$FAIL"
