import Foundation

/// OSC 地址 → `(kind, idx)` 的反向解析。
///
/// 与 `MixerSpec.address(kind:idx:)` 互逆，规则逐条对齐服务端
/// `x32_simulator.py` 的 `match_address()`。
///
/// 桥接引擎靠它把"真台回读的裸地址"还原成可比较的目标，
/// 进而判断这是自己写入的回声还是面板上的外部变化。
public enum OscAddressParser {

    public struct Target: Equatable, Sendable {
        public let kind: String
        public let idx: Int
        public init(kind: String, idx: Int) {
            self.kind = kind
            self.idx = idx
        }
    }

    /// 去掉真机 FX 返回常见的 `01L` / `01R` 尾缀
    private static func stripLR(_ s: String) -> String {
        var t = s
        while let last = t.last, last == "L" || last == "R" { t.removeLast() }
        return t
    }

    private static let auxGroups: Set<String> = ["auxin", "usb", "fxret", "mtx"]

    /// 解析地址。返回 `nil` 表示该地址与推子/静音/成员无关（如名称、场景、电平表）。
    public static func parse(_ address: String) -> Target? {
        let segs = address.split(separator: "/").map(String.init)

        // /ch/NN/mix/<fader|on|dca>
        if segs.count == 4, segs[0] == "ch", segs[2] == "mix" {
            guard let idx = Int(segs[1]) else { return nil }
            switch segs[3] {
            case "fader": return Target(kind: "ch_fader", idx: idx)
            case "on":    return Target(kind: "ch_on", idx: idx)
            case "dca":   return Target(kind: "ch_dca", idx: idx)   // 位掩码
            default:      return nil
            }
        }

        // 真机固件也有 /ch/NN/grp/dca 的写法，一并兼容
        if segs.count == 4, segs[0] == "ch", segs[2] == "grp", segs[3] == "dca" {
            guard let idx = Int(segs[1]) else { return nil }
            return Target(kind: "ch_dca", idx: idx)
        }

        // /bus/NN/mix/<fader|on>
        if segs.count == 4, segs[0] == "bus", segs[2] == "mix" {
            guard let idx = Int(segs[1]) else { return nil }
            if segs[3] == "fader" { return Target(kind: "bus_fader", idx: idx) }
            if segs[3] == "on" { return Target(kind: "bus_on", idx: idx) }
            return nil
        }

        // /dca/NN/<fader|on>   （两位补零，但没有占位符依赖）
        if segs.count == 3, segs[0] == "dca" {
            guard let idx = Int(segs[1]) else { return nil }
            if segs[2] == "fader" { return Target(kind: "dca_fader", idx: idx) }
            if segs[2] == "on" { return Target(kind: "dca_on", idx: idx) }
            return nil
        }

        // /auxin|usb|fxret|mtx/NN/mix/<fader|on>
        if segs.count == 4, auxGroups.contains(segs[0]), segs[2] == "mix" {
            guard let idx = Int(stripLR(segs[1])) else { return nil }
            if segs[3] == "fader" { return Target(kind: "\(segs[0])_fader", idx: idx) }
            if segs[3] == "on" { return Target(kind: "\(segs[0])_on", idx: idx) }
            return nil
        }

        // /main/st/mix/<fader|on>   （idx 固定 0）
        if segs.count == 4, segs[0] == "main", segs[1] == "st", segs[2] == "mix" {
            if segs[3] == "fader" { return Target(kind: "main_fader", idx: 0) }
            if segs[3] == "on" { return Target(kind: "main_on", idx: 0) }
            return nil
        }

        return nil
    }

    /// 取消息首个参数的数值（float / int），其余类型返回 nil
    public static func numericValue(_ message: OscMessage) -> Float? {
        guard let first = message.args.first else { return nil }
        switch first {
        case .float(let f): return f
        case .int(let i):   return Float(i)
        default:            return nil
        }
    }
}
