import Foundation

/// X32/M32 分组尺寸、数值语义、dB 曲线与地址生成。
///
/// 严格对齐《共享协议规范.md》第 3–6 节；与 Android `core/X32.kt`、
/// 服务端 `X32Simulator/x32_simulator.py` 保持逐项一致。
///
/// 三个必须记住的坑：
///  1. DCA 地址必须两位补零（`/dca/01/fader`）
///  2. Main 地址没有 `%02d` 占位符，绝不能做格式化替换
///  3. 场景地址不补零（`/scene/2/load`）
public enum MixerSpec {

    public static let defaultPort: UInt16 = 10023

    /// 各组通道数量（main 的 idx 固定为 0，单独处理）
    public static let groupCounts: [(group: String, count: Int)] = [
        ("ch", 32), ("bus", 16), ("dca", 8), ("auxin", 6), ("usb", 2), ("fxret", 8), ("mtx", 6),
    ]

    public static func count(of group: String) -> Int {
        groupCounts.first { $0.group == group }?.count ?? 0
    }

    public static func label(of group: String) -> String {
        switch group {
        case "ch":    return "通道"
        case "bus":   return "Bus"
        case "dca":   return "DCA"
        case "auxin": return "AuxIn"
        case "usb":   return "USB"
        case "fxret": return "FX"
        case "mtx":   return "Matrix"
        case "main":  return "Main"
        default:      return group
        }
    }

    /// `"ch_fader"` → `"ch"`；`"ch_dca"` → `"ch"`
    public static func kindGroup(_ kind: String) -> String {
        guard let cut = kind.lastIndex(of: "_") else { return kind }
        return String(kind[kind.startIndex..<cut])
    }

    /// 该 kind 覆盖的目标数量
    public static func count(forKind kind: String) -> Int {
        let group = kindGroup(kind)
        if group == "main" { return 1 }
        return count(of: group)
    }

    /// 索引下界（main 固定 0，其余从 1 起）
    public static func lowerBound(forKind kind: String) -> Int {
        kindGroup(kind) == "main" ? 0 : 1
    }

    // MARK: - 曲线

    public static let curves = ["linear", "ease_out", "ease_in", "smooth"]

    /// `t` 为 0→1 归一化进度
    public static func applyCurve(_ t: Float, _ curve: String) -> Float {
        switch curve {
        case "ease_out": return 1 - (1 - t) * (1 - t)          // 先快后慢
        case "ease_in":  return t * t                          // 先慢后快
        case "smooth":   return t * t * (3 - 2 * t)            // S 形缓入缓出
        default:         return t                              // linear
        }
    }

    public static func curveLabel(_ curve: String) -> String {
        switch curve {
        case "ease_out": return "先快后慢"
        case "ease_in":  return "先慢后快"
        case "smooth":   return "S 形缓入缓出"
        default:         return "线性"
        }
    }

    // MARK: - dB 曲线

    /// 推子行程(0..1) → dB。`0.75 = 0 dB`，`1.0 = +10 dB`，`0.0 = -∞`
    public static func faderToDb(_ f: Float) -> Float {
        if f <= 0 { return -90 }
        if f >= 0.75 { return (f - 0.75) / 0.25 * 10 }
        // 历史 bug：此处曾有 `if f <= 0.001 { return -90 }`，把 -57.5dB 以下的整段
        // 塌陷成 -∞，导致 -60dB 无法往返。改为对下限做 clamp，保住低段分辨率。
        return max(-90, 20 * log10(f / 0.75))
    }

    /// dB → 推子行程(0..1)，`faderToDb` 的逆运算
    public static func dbToFader(_ dbIn: Float) -> Float {
        let db = min(max(dbIn, -90), 10)
        if db <= -89.5 { return 0 }
        if db >= 10 { return 1 }
        if db >= 0 { return 0.75 + db / 10 * 0.25 }
        return 0.75 * Float(pow(10.0, Double(db) / 20.0))
    }

    /// 推子值 → 显示用 dB 字符串
    public static func formatDb(_ f: Float) -> String {
        let db = faderToDb(f)
        if db <= -89.5 { return "-∞" }
        return db >= 0 ? String(format: "+%.1f", db) : String(format: "%.1f", db)
    }

    // MARK: - 地址生成

    public static func channelFader(_ i: Int) -> String { String(format: "/ch/%02d/mix/fader", i) }
    public static func channelOn(_ i: Int) -> String { String(format: "/ch/%02d/mix/on", i) }
    public static func busFader(_ i: Int) -> String { String(format: "/bus/%02d/mix/fader", i) }
    public static func busOn(_ i: Int) -> String { String(format: "/bus/%02d/mix/on", i) }

    /// ⚠️ DCA 两位补零
    public static func dcaFader(_ i: Int) -> String { String(format: "/dca/%02d/fader", i) }
    public static func dcaOn(_ i: Int) -> String { String(format: "/dca/%02d/on", i) }

    /// 通道 DCA 成员位掩码（bit0 = DCA1）。
    ///
    /// 以模拟器 / 桥接规范为准使用 `mix` 段；解析端同时兼容真机的 `grp` 写法。
    public static func channelDcaMask(_ i: Int) -> String { String(format: "/ch/%02d/mix/dca", i) }

    /// ⚠️ 场景不补零
    public static func sceneLoad(_ scene: Int) -> String { "/scene/\(scene)/load" }

    public static func nameAddress(group: String, idx: Int) -> String? {
        switch group {
        case "ch":    return String(format: "/ch/%02d/config/name", idx)
        case "bus":   return String(format: "/bus/%02d/config/name", idx)
        case "dca":   return String(format: "/dca/%02d/config/name", idx)
        case "auxin": return String(format: "/auxin/%02d/config/name", idx)
        case "usb":   return String(format: "/usb/%02d/config/name", idx)
        case "fxret": return String(format: "/fxret/%02d/config/name", idx)
        case "mtx":   return String(format: "/mtx/%02d/config/name", idx)
        case "main":  return "/main/st/config/name"
        default:      return nil
        }
    }

    public static func faderAddress(kind: String, idx: Int) -> String? {
        switch kind {
        case "ch_fader":    return channelFader(idx)
        case "bus_fader":   return busFader(idx)
        case "dca_fader":   return dcaFader(idx)
        case "auxin_fader": return String(format: "/auxin/%02d/mix/fader", idx)
        case "usb_fader":   return String(format: "/usb/%02d/mix/fader", idx)
        case "fxret_fader": return String(format: "/fxret/%02d/mix/fader", idx)
        case "mtx_fader":   return String(format: "/mtx/%02d/mix/fader", idx)
        case "main_fader":  return "/main/st/mix/fader"   // 无占位符
        default:            return nil
        }
    }

    public static func onAddress(kind: String, idx: Int) -> String? {
        switch kind {
        case "ch_on":    return channelOn(idx)
        case "bus_on":   return busOn(idx)
        case "dca_on":   return dcaOn(idx)
        case "auxin_on": return String(format: "/auxin/%02d/mix/on", idx)
        case "usb_on":   return String(format: "/usb/%02d/mix/on", idx)
        case "fxret_on": return String(format: "/fxret/%02d/mix/on", idx)
        case "mtx_on":   return String(format: "/mtx/%02d/mix/on", idx)
        case "main_on":  return "/main/st/mix/on"         // 无占位符
        default:         return nil
        }
    }

    /// 统一入口：内部已处理 Main 无占位符与 DCA 位掩码的特例。
    public static func address(kind: String, idx: Int) -> String? {
        if kind == "ch_dca" { return channelDcaMask(idx) }
        if kind.hasSuffix("_fader") { return faderAddress(kind: kind, idx: idx) }
        if kind.hasSuffix("_on") { return onAddress(kind: kind, idx: idx) }
        return nil
    }

    /// 该 kind 的目标是否合法
    public static func isValidTarget(kind: String, idx: Int) -> Bool {
        guard kind.hasSuffix("_fader") || kind.hasSuffix("_on") || kind == "ch_dca" else { return false }
        let group = kindGroup(kind)
        if group == "main" { return idx == 0 }
        let n = count(of: group)
        return n > 0 && idx >= 1 && idx <= n
    }
}
