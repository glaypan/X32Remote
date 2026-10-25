import Foundation

/// 手机 App 的扫码配对码（协议见《共享协议规范》§16.9，服务端实现 `x32sim/pair.py`）。
///
/// 为什么 App 不能只扫网页那张码：
/// 网页码编码的是 `http://<ip>:<web>/`，里面那个端口是 **HTTP** 的；
/// App 走 OSC/UDP，端口默认 10023 且可能被用户改过。两者在改过端口时分叉，
/// 而且错得很安静——连不上、也没有任何回包提示。
///
/// 所以服务端另给一张 `x32remote://pair?v=1&host=…&osc=…&web=…` 的码。
/// 但解析器**同时接受**网页地址与 `host:port`：现场最常见的动作，就是
/// 拿 App 去扫屏幕上那张浏览器二维码。
public struct PairCode: Equatable, Sendable {
    public let host: String
    public let oscPort: Int
    public let webPort: Int?

    public static let defaultOscPort = 10023

    public init(host: String, oscPort: Int = PairCode.defaultOscPort, webPort: Int? = nil) {
        self.host = host
        self.oscPort = oscPort
        self.webPort = webPort
    }

    /// 给界面用的一句话摘要
    public var summary: String {
        if let web = webPort { return "\(host):\(oscPort)（网页 \(web)）" }
        return "\(host):\(oscPort)"
    }

    // MARK: - 解析

    /// 解析失败返回 nil（调用方提示"无法识别的二维码"，不要猜一个地址去连）。
    public static func parse(_ raw: String) -> PairCode? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 200 else { return nil }

        let lower = text.lowercased()
        var host = ""
        var osc = defaultOscPort
        var web: Int?

        if lower.hasPrefix("x32remote://") {
            guard let comps = URLComponents(string: text) else { return nil }
            // netloc 只允许空或 pair：别的 host 说明是伪造/串了别的 deep link
            guard comps.host == nil || comps.host == "pair" else { return nil }
            let items = comps.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first(where: { $0.name == name })?.value
            }
            host = (value("host") ?? "").trimmingCharacters(in: .whitespaces)
            if let rawOsc = value("osc"), !rawOsc.isEmpty {
                guard let n = Int(rawOsc), validPort(n) else { return nil }
                osc = n
            }
            if let rawWeb = value("web"), !rawWeb.isEmpty {
                guard let n = Int(rawWeb), validPort(n) else { return nil }
                web = n
            }
        } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let comps = URLComponents(string: text), let h = comps.host else { return nil }
            host = h
            if let w = comps.port {
                guard validPort(w) else { return nil }
                web = w
            } else if let digits = firstPortDigits(text) {
                // Foundation 对超范围端口可能直接回 nil（而不是报错），
                // 那样 "…:99999/" 就会被当成"没写端口"。这里补一刀，按原文数字判。
                guard let n = Int(digits), validPort(n) else { return nil }
                web = n
            }
            osc = defaultOscPort        // 网页地址里没有 OSC 端口，只能按默认
        } else {
            // host[:port] 或裸 host；允许后面跟路径（有人会把地址连同 / 一起复制）
            let head = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? text
            let parts = head.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 2 {
                host = String(parts[0]).trimmingCharacters(in: .whitespaces)
                guard let n = Int(parts[1]), validPort(n) else { return nil }
                osc = n
            } else {
                host = head.trimmingCharacters(in: .whitespaces)
            }
        }

        guard validHost(host) else { return nil }
        return PairCode(host: host, oscPort: osc, webPort: web)
    }

    /// 从 `http(s)://host:port…` 里抠出端口数字（Foundation 解析失败时的兜底）
    private static func firstPortDigits(_ text: String) -> String? {
        guard let r = text.range(of: #"^https?://[^/?#]+:(\d+)"#,
                                 options: [.regularExpression, .caseInsensitive]) else { return nil }
        let chunk = text[r]
        guard let colon = chunk.lastIndex(of: ":") else { return nil }
        return String(chunk[chunk.index(after: colon)...])
    }

    // MARK: - 校验（与服务端同一套规则）
    static func validPort(_ p: Int) -> Bool { p >= 1 && p <= 65535 }

    static func validHost(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, host.count <= 63 else { return false }
        guard host.range(of: #"^[A-Za-z0-9]([A-Za-z0-9.\-]{0,62})$"#,
                         options: .regularExpression) != nil else { return false }
        let lower = host.lowercased()
        // 回环地址扫了只会连到手机自己 —— 一律当非法
        if lower == "localhost" || lower.hasPrefix("127.") || lower == "0.0.0.0" || lower == "::1" {
            return false
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4 && octets.allSatisfy({ Int($0) != nil }) {
            return octets.allSatisfy { (Int($0) ?? 999) <= 255 }
        }
        return true
    }
}
