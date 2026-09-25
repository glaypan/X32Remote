#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 X32Client.swift 的 Network.framework 桩版本，供 Windows 本地类型检查。

Windows 上没有 Apple 的 Network.framework，核心库的 X32Client 无法直接
`swiftc -typecheck`。本脚本把 `import Network` 去掉、追加一份签名对齐官方
API 的桩，得到一个可本地检查的同源文件。桩不参与云端构建。

用法:
  python network_stub.py <输出路径>
默认输出到 <仓库根>/.localverify/src/Network/X32Client.swift
"""
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
SRC = ROOT / "Sources/X32RemoteCore/Network/X32Client.swift"

STUB = '''

// ================= 仅用于本地类型检查的 Network.framework 桩 =================
// 签名对照 Apple 官方 API；不参与云端构建，也不参与任何实际运行。
final class NWError: Error {}

struct NWEndpoint {
    struct Host {
        init(_ string: String) {}
    }
    struct Port {
        init?(rawValue: UInt16) {}
        init?(string: String) {}
    }
}

final class NWParameters {
    static var udp: NWParameters { NWParameters() }
}

final class NWConnection {
    enum State {
        case setup
        case waiting(NWError)
        case preparing
        case ready
        case failed(NWError)
        case cancelled
    }
    final class ContentContext {
        static let finalMessage = ContentContext()
    }
    enum SendCompletion {
        case idempotent
        case contentProcessed((NWError?) -> Void)
    }
    init(host: NWEndpoint.Host, port: NWEndpoint.Port, using: NWParameters) {}
    var stateUpdateHandler: ((NWConnection.State) -> Void)?
    func start(queue: DispatchQueue) {}
    func cancel() {}
    func send(content: Data, completion: NWConnection.SendCompletion) {}
    func receiveMessage(completion: @escaping (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void) {}
}
'''


def main() -> int:
    if len(sys.argv) > 1:
        out = pathlib.Path(sys.argv[1])
    else:
        out = ROOT / ".localverify/src/Network/X32Client.swift"
    out.parent.mkdir(parents=True, exist_ok=True)

    src = SRC.read_text(encoding="utf-8")
    if "import Network" not in src:
        print("错误: X32Client.swift 已不再 import Network，桩已失效，请更新 network_stub.py。",
              file=sys.stderr)
        return 1
    out.write_text(src.replace("import Network", "") + STUB, encoding="utf-8")
    print("已写出 %s" % out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
