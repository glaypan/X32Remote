import Foundation

/// 通道参数的**元数据模型**（label / 量程 / 页签 / OSC 地址模板）。
///
/// 数据的唯一来源是模拟器仓的 `x32sim/params.py`，经
/// `tools/export_param_specs.py` 生成为 `ParamSpecs+Generated.swift`。
/// App 直连真台只走 OSC，真台不回任何元信息，所以这张表必须随包携带。
/// **禁止在这里手写参数** —— 手写一份就等于多一份要同步的真相。
public struct ParamRow: Codable, Equatable, Sendable, Identifiable {
    /// 语义 kind（`ch_trim` / `send_level` …），卡片与预设用它
    public let kind: String
    public let field: String
    /// OSC 地址模板，可能有 0 个或 1 个 `%02d`（main 没有路号）
    public let address: String
    public let label: String
    /// "float" | "int" | "bool"
    public let ty: String
    public let lo: Double
    public let hi: Double
    public let step: Double
    public let dec: Int
    public let unit: String
    /// 对数档位数（>0 表示滑杆应按对数映射，否则线性档位会挤在高端）
    public let logSteps: Int
    public let logDesc: Bool
    /// 真台枚举名（EQ 类型 / 低切斜率 …）
    public let labels: [String]?
    /// 数值型枚举（压缩比：真台用 12 档比值）
    public let enumValues: [Double]?
    /// 线上表示：`value` 传字面值，`index` 传下标（压缩比）
    public let enumWire: String
    public let defaultValue: Double
    /// 出厂值未经真机核对（界面标 ⚠️）
    public let unverified: Bool
    /// 页签：pre | gate | dyn | eq（服务端 `spec_section` 下发，三端共用）
    public let section: String

    public var id: String { field }
    public var isBool: Bool { ty == "bool" }
    public var isInt: Bool { ty == "int" || ty == "bool" }

    enum CodingKeys: String, CodingKey {
        case kind = "k", field = "f", address = "a", label = "l", ty = "t"
        case lo, hi, step = "st", dec, unit = "u"
        case logSteps = "lg", logDesc = "ld", labels = "lb"
        case enumValues = "en", enumWire = "ew", defaultValue = "dv"
        case unverified = "un", section = "sec"
    }

    /// 具体一路的 OSC 地址（main 没有路号）
    public func address(idx: Int) -> String {
        guard address.contains("%") else { return address }
        return String(format: address, idx)
    }

    /// 界面显示值（枚举参数优先显示中文名）
    public func display(_ v: Double) -> String {
        if isBool { return v != 0 ? "开" : "关" }
        if field == "pan" {
            let n = Int(v.rounded())
            if n == 0 { return "C" }
            return n < 0 ? "L\(-n)" : "R\(n)"
        }
        if let labels, !labels.isEmpty {
            let i = Int(v.rounded())
            return (i >= 0 && i < labels.count) ? labels[i] : "\(i)"
        }
        let s = String(format: "%.\(dec)f", v)
        return unit.isEmpty ? s : "\(s) \(unit)"
    }

    /// 写值 → OSC 参数类型。这里必须处理 `enumWire == "index"`：
    /// `dyn_ratio` 本地存 4.0（4:1），线上是下标 3；直接发 4.0 会变成第 4 档。
    public func wireArgument(_ value: Double) -> OscArgument {
        if isBool { return .int(value != 0 ? 1 : 0) }
        if let enumValues, enumWire == "index" {
            var best = 0
            var bestD = Double.greatestFiniteMagnitude
            for (i, ev) in enumValues.enumerated() where abs(ev - value) < bestD {
                best = i
                bestD = abs(ev - value)
            }
            return .int(Int32(best))
        }
        if ty == "int" { return .int(Int32(value.rounded())) }
        return .float(Float(value))
    }

    public func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return defaultValue }
        return min(max(v, lo), hi)
    }
}

/// 一类通道的**能力**（由登记表反推：没有该参数就是真台没有这个功能）
public struct ParamGroupCaps: Codable, Equatable, Sendable {
    public let label: String
    public let short: String
    public let size: Int
    public let pre: Int
    public let gate: Int
    public let dyn: Int
    public let ins: Int
    /// EQ 段数（0 = 无 EQ）
    public let eq: Int
    public let pan: Int
    /// 发送目标数（0 = 无发送）
    public let send: Int
    /// 是否有发送取点（只有 ch/auxin/fxret 有）
    public let tap: Int
    public let sendBase: Int
    public let sendMax: Int
    /// OSC 前缀（真台拼写：fxret → `/fxrtn`；main → `/main/st` 且没有路号）
    public let osc: String

    public var hasPre: Bool { pre != 0 }
    public var hasGate: Bool { gate != 0 }
    public var hasDyn: Bool { dyn != 0 }
    public var hasIns: Bool { ins != 0 }
    public var hasPan: Bool { pan != 0 }
    public var hasSend: Bool { send > 0 }
    public var hasTap: Bool { tap != 0 }

    /// 本组的一路前缀（main 没有路号，地址就是 /main/st）
    public func itemPrefix(_ idx: Int) -> String {
        self.osc == "/main/st" ? self.osc : String(format: "%@/%02d", self.osc, idx)
    }

    enum CodingKeys: String, CodingKey {
        case label, short, size, pre, gate, dyn, ins, eq, pan, send, tap
        case sendBase, sendMax, osc
    }
}

public struct ParamSpecPayload: Codable, Sendable {
    public var v: Int
    public var note: String
    public var groups: [String: ParamGroupCaps]
    public var specs: [String: [ParamRow]]
}

/// 参数表的查询入口（进程内单例，来自内嵌 JSON）
public enum ParamTable {
    public static let payload = ParamSpecsGenerated.payload

    /// 面板页签顺序 = 通道类型顺序
    public static let groupOrder = ["ch", "bus", "auxin", "fxret", "mtx", "main"]

    public static func caps(_ group: String) -> ParamGroupCaps? { payload.groups[group] }
    public static func rows(_ group: String) -> [ParamRow] { payload.specs[group] ?? [] }

    public static func row(_ group: String, _ field: String) -> ParamRow? {
        rows(group).first { $0.field == field }
    }

    public static func groupLabel(_ group: String) -> String {
        caps(group)?.label ?? group
    }

    /// 列表里的短标签（Ch 01 / Bus 03 / Main）
    public static func itemLabel(_ group: String, idx: Int) -> String {
        guard let c = caps(group) else { return "\(group) \(idx)" }
        return group == "main" ? c.label : String(format: "%@ %02d", c.short, idx)
    }

    // MARK: - 发送（二维：源 × 目标）

    /// 发送地址：`/<前缀>/<源>/mix/<目标>/level|on|type`
    ///
    /// 取点 (`type`) **只对奇数目标定义**（真台按 1&2 / 3&4 成对共享）——
    /// 偶数目标问 type 会拿到配对奇数那个的值，读没错，但写就必须落到奇数上，
    /// 否则同一份真相有两个入口。这里统一：查偶数 → 用奇数地址。
    public static func sendAddress(group: String, src: Int, bus: Int, field: String) -> String? {
        guard let c = caps(group), c.hasSend, bus >= 1, bus <= c.send else { return nil }
        let target = (field == "tap" && bus % 2 == 0) ? bus - 1 : bus
        let seg = field == "tap" ? "type" : field
        if group == "main" {
            return String(format: "%@/mix/%02d/%@", c.osc, target, seg)
        }
        return String(format: "%@/%02d/mix/%02d/%@", c.osc, src, target, seg)
    }

    /// 发送值在 `RemoteState.params` 里的键（统一走这个函数，别手拼）
    public static func sendKey(group: String, src: Int, bus: Int, field: String) -> String {
        String(format: "send/%@/%02d/%02d/%@", group, src, bus, field)
    }

    /// 一组的发送参数（不是登记表里的行参数，单独构造）
    public static func sendRows(group: String) -> [ParamRow] {
        guard let c = caps(group), c.hasSend else { return [] }
        var out = [
            ParamRow(kind: "\(group)_send_level", field: "level", address: "",
                     label: "发送电平", ty: "float", lo: 0, hi: 1, step: 0,
                     dec: 3, unit: "", logSteps: 0, logDesc: false, labels: nil,
                     enumValues: nil, enumWire: "value", defaultValue: 0,
                     unverified: true, section: "send"),
            ParamRow(kind: "\(group)_send_on", field: "on", address: "",
                     label: "发送开关", ty: "bool", lo: 0, hi: 1, step: 0,
                     dec: 0, unit: "", logSteps: 0, logDesc: false, labels: nil,
                     enumValues: nil, enumWire: "value", defaultValue: 0,
                     unverified: true, section: "send"),
        ]
        if c.hasTap {
            out.append(ParamRow(kind: "\(group)_send_tap", field: "tap", address: "",
                                label: "取点", ty: "int", lo: 0, hi: 4, step: 0,
                                dec: 0, unit: "", logSteps: 0, logDesc: false,
                                labels: ["<-EQ", "EQ->", "PRE", "POST", "GRP"],
                                enumValues: nil, enumWire: "value", defaultValue: 3,
                                unverified: true, section: "send"))
        }
        return out
    }

    // MARK: - 地址反查（OSC 回读 → 参数键）

    /// 具体地址 → (group, idx, field)。首次使用时构建全表（约 3000 条），
    /// 之后 O(1)。回读频率高、构建只一次，比每次正则扫描划算。
    private static let reverseMap: [String: (String, Int, String)] = {
        var map: [String: (String, Int, String)] = [:]
        for g in groupOrder {
            let size = payload.groups[g]?.size ?? 0
            for r in rows(g) {
                for i in 1...max(size, 1) {
                    map[r.address(idx: i)] = (g, i, r.field)
                }
            }
        }
        return map
    }()

    public static func parse(address: String) -> (group: String, idx: Int, field: String)? {
        reverseMap[address]
    }

    /// 发送地址的反查（键直接是 `sendKey`，与行参数的键空间分开）
    private static let sendReverseMap: [String: String] = {
        var map: [String: String] = [:]
        for g in groupOrder {
            guard let c = caps(g), c.hasSend else { continue }
            let srcMax = max(c.sendMax, 1)
            for src in 1...srcMax {
                for bus in 1...c.send {
                    for f in (c.hasTap ? ["level", "on", "tap"] : ["level", "on"]) {
                        if let a = sendAddress(group: g, src: src, bus: bus, field: f) {
                            map[a] = sendKey(group: g, src: src, bus: bus, field: f)
                        }
                    }
                }
            }
        }
        return map
    }()

    public static func parseSend(address: String) -> String? { sendReverseMap[address] }
}
