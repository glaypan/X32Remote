import Foundation

/// 自动增益 / 自动推子：电脑端服务的 HTTP 客户端（`/api/rider`）。
///
/// 控制律跑在电脑上（要读电平表、50ms 一拍），手机只做配置与显示。
/// 协议与网页端完全一致，避免两端行为漂移。
public struct RiderChannel: Codable, Identifiable, Sendable {
    public var id: Int { ch }
    public let ch: Int
    public var on: Bool
    public var target: Double
    public var mode: String        // fader / gain
    public var speed: String       // slow / medium / fast
    public var tap: String?
    public var sidechain: Int?
    public var level: Double?      // 无信号为 nil
    public var applied: Double?
    public var curve: Bool?
    public var paused: Bool?
    public var targetNow: Double?

    enum CodingKeys: String, CodingKey {
        case ch, on, target, mode, speed, tap, sidechain, level, applied, curve, paused
        case targetNow = "target_now"
    }

    public init(ch: Int, on: Bool = false, target: Double = -18,
                mode: String = "fader", speed: String = "medium",
                tap: String? = nil, sidechain: Int? = nil, level: Double? = nil,
                applied: Double? = nil, curve: Bool? = nil, paused: Bool? = nil,
                targetNow: Double? = nil) {
        self.ch = ch
        self.on = on
        self.target = target
        self.mode = mode
        self.speed = speed
        self.tap = tap
        self.sidechain = sidechain
        self.level = level
        self.applied = applied
        self.curve = curve
        self.paused = paused
        self.targetNow = targetNow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ch = try c.decode(Int.self, forKey: .ch)
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? false
        target = try c.decodeIfPresent(Double.self, forKey: .target) ?? -18
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "fader"
        speed = try c.decodeIfPresent(String.self, forKey: .speed) ?? "medium"
        tap = try c.decodeIfPresent(String.self, forKey: .tap)
        sidechain = try c.decodeIfPresent(Int.self, forKey: .sidechain)
        level = try c.decodeIfPresent(Double.self, forKey: .level)
        applied = try c.decodeIfPresent(Double.self, forKey: .applied)
        curve = try c.decodeIfPresent(Bool.self, forKey: .curve)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused)
        targetNow = try c.decodeIfPresent(Double.self, forKey: .targetNow)
    }

    /// 显示的当前目标：曲线生效时用 target_now，否则用固定值
    public var effectiveTarget: Double { targetNow ?? target }
    public var isGain: Bool { mode == "gain" }
    public var speedLabel: String {
        switch speed {
        case "slow": return "慢"
        case "fast": return "快"
        default: return "中"
        }
    }
}

public struct RiderSnapshot: Sendable {
    public var enabled: Bool
    public var channels: [RiderChannel]

    public init(enabled: Bool, channels: [RiderChannel]) {
        self.enabled = enabled
        self.channels = channels
    }
}

public enum RiderAPI {
    public static func baseURL(host: String, port: Int) -> URL? {
        URL(string: "http://\(host):\(port)")
    }

    private static func request(_ url: URL, body: [String: Any]?) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.5
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "RiderAPI", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) \(text.prefix(80))"])
        }
        return data
    }

    /// 解析 {"enabled":true,"channels":{"1":{...}}}；POST 返回外面包了一层 {"ok":true,"rider":{...}}
    private static func decode(_ data: Data) throws -> RiderSnapshot {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let root = (obj["rider"] as? [String: Any]) ?? obj
        let enabled = (root["enabled"] as? Bool) ?? true
        let channels = (root["channels"] as? [String: Any]) ?? [:]
        var list: [RiderChannel] = []
        for (key, value) in channels {
            guard let n = Int(key), let dict = value as? [String: Any],
                  let d = try? JSONSerialization.data(withJSONObject: dict) else { continue }
            if let ch = try? JSONDecoder().decode(RiderChannel.self, from: d) {
                list.append(ch)
            } else {
                list.append(RiderChannel(ch: n,
                                         on: (dict["on"] as? Bool) ?? false,
                                         target: (dict["target"] as? Double) ?? -18))
            }
        }
        list.sort { $0.ch < $1.ch }
        return RiderSnapshot(enabled: enabled, channels: list)
    }

    public static func fetch(host: String, port: Int) async throws -> RiderSnapshot {
        guard let base = baseURL(host: host, port: port) else {
            throw NSError(domain: "RiderAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "地址无效"])
        }
        return try decode(try await request(base.appendingPathComponent("api/rider"), body: nil))
    }

    public static func post(host: String, port: Int, body: [String: Any]) async throws -> RiderSnapshot {
        guard let base = baseURL(host: host, port: port) else {
            throw NSError(domain: "RiderAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "地址无效"])
        }
        return try decode(try await request(base.appendingPathComponent("api/rider"), body: body))
    }
}

extension RiderChannel {
    /// 新建一条未启用的通道配置（App 侧添加用）
    public static func make(_ ch: Int) -> RiderChannel {
        RiderChannel(ch: ch, on: false, target: -18, mode: "fader", speed: "medium")
    }
}
