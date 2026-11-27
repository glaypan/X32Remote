import Foundation
// Windows/Linux 的 Foundation 把 URLSession 拆到 FoundationNetworking；
// Apple 平台没有这个模块，所以必须用 canImport 包一层。
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 效果参数**可写性表**：当前控台上哪些算法参数没有地址（界面标"本控台未标定"）。
///
/// 为什么 App 要单独拉一次：网页端每个参数在 `/api/state` 里自带 `w` 布尔字段，
/// 但 App 是 OSC 直连，从来没消费过那份 HTTP 状态流。进效果器详情页时打一次
/// `GET /api/fxcaps` 就够了（几百字节，见 `x32sim/httpapi.py`）。
///
/// **拉不到一律当"全部可写"**：连真台 X32 时压根没有这个 HTTP 服务；
/// 若因为请求失败就把滑杆全灰掉，等于凭空把功能关了。宁可让用户拖了没反应
/// （真台会安全地拒掉 NODE NOT FOUND），也不能禁用本来能用的参数。
///
/// 服务端实现见 `ConsoleProfile.fx_param_caps()`：WING 返回每槽可写的 par 号清单，
/// X32 / M32 返回 nil（表示"没有这个概念，全可写"）。
public struct FxParamCaps: Sendable, Equatable {
    /// 控台 id（wing / x32 / m32 …），仅用于提示文案
    public let console: String
    /// true = 该控台没有"未标定"概念（X32 / M32），一切可写
    public let all: Bool
    /// 槽号 → 可写的 par 号集合；**空集合**代表这个槽一个参数都不能写
    public let slots: [Int: Set<Int>]

    public init(console: String, all: Bool, slots: [Int: Set<Int>]) {
        self.console = console
        self.all = all
        self.slots = slots
    }

    /// 拉不到 / 不适用时的默认值：全部可写。**不要**拿它表示"全都不能写"
    public static let unrestricted = FxParamCaps(console: "", all: true, slots: [:])

    /// 缺这个槽 → 不猜，放行（服务端本该把 1..N 都列全，缺键说明对端不是本服务）
    public func allows(slot: Int, par: Int) -> Bool {
        if all { return true }
        guard let set = slots[slot] else { return true }
        return set.contains(par)
    }

    public func blockedCount(slot: Int, pars: [Int]) -> Int {
        all ? 0 : pars.filter { !allows(slot: slot, par: $0) }.count
    }
}

/// `/api/fxcaps` 的 HTTP 客户端（与 `RiderAPI` 同一台电脑端服务）。
public enum FxParamCapsAPI {

    public static func baseURL(host: String, port: Int) -> URL? {
        URL(string: "http://\(host):\(port)")
    }

    public static func fetch(host: String, port: Int) async throws -> FxParamCaps {
        guard let base = baseURL(host: host, port: port) else {
            throw NSError(domain: "FxParamCapsAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "地址无效"])
        }
        var req = URLRequest(url: base.appendingPathComponent("api/fxcaps"))
        req.timeoutInterval = 2.5
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "FxParamCapsAPI", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) \(text.prefix(80))"])
        }
        return try decode(data)
    }

    /// `{"console":"wing","all":false,"slots":{"1":[1,2,5],"2":[]}}`
    ///
    /// JSON 的对象键只能是字符串，槽号必须转回 Int；缺 `all` 字段按"全可写"处理
    /// （老服务端没有这个接口时不该误灰）。
    public static func decode(_ data: Data) throws -> FxParamCaps {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let all = (obj["all"] as? Bool) ?? true
        let console = (obj["console"] as? String) ?? ""
        let raw = (obj["slots"] as? [String: Any]) ?? [:]
        var slots: [Int: Set<Int>] = [:]
        for (key, value) in raw {
            guard let n = Int(key), let arr = value as? [Any] else { continue }
            var set = Set<Int>()
            for v in arr {
                if let i = v as? Int {
                    set.insert(i)
                } else if let d = v as? Double {
                    set.insert(Int(d))
                }
            }
            slots[n] = set
        }
        return FxParamCaps(console: console, all: all, slots: slots)
    }
}
