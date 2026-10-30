import Foundation

/// 一个效果参数的标定规格 (来自 X32Simulator/x32sim/fxlib.py, 随 App 分发)。
/// OSC 协议本身不带这些元数据 —— 真台只回数值, 中文名/量程/枚举只能本地带。
public struct FxParamSpec: Codable, Equatable, Sendable {
    public let p: Int              // par 号 (OSC 地址 /fx/<槽>/par/<两位补零>)
    public let field: String       // 稳定标识 (API/写入用)
    public let label: String       // 中文名 (界面显示)
    public let unit: String        // 单位 (ms/s/Hz/dB, 可能为空)
    public let kind: String        // "f" 数值 / "i" 枚举
    public let lo: Double
    public let hi: Double
    public let opts: [String]?     // kind == "i" 时: 选项中文名, 下标 = 真台 enum 索引

    public var isEnum: Bool { kind == "i" }

    /// 把任意值钳进量程 (枚举四舍五入到整数索引) —— 与服务端 fx_par_clamp 同语义
    public func clamp(_ v: Double) -> Double {
        let c = min(max(v.isFinite ? v : 0, lo), hi)
        return isEnum ? c.rounded() : c
    }

    /// 显示用小数位: 步长感知, 大量程 (频率 1000–20000) 不显示小数
    public var decimals: Int {
        let span = hi - lo
        if span >= 100 { return 0 }
        if span >= 10 { return 1 }
        return 2
    }

    public func display(_ v: Double) -> String {
        if isEnum, let opts = opts {
            let i = Int(v.rounded())
            return opts.indices.contains(i) ? opts[i] : "\(i)"
        }
        return String(format: "%.\(decimals)f", v) + (unit.isEmpty ? "" : " \(unit)")
    }
}

/// 一种效果算法的标定 (61 种之一)
public struct FxAlgoSpec: Codable, Equatable, Sendable {
    public let label: String       // 中文名
    public let cat: String         // 分类 (reverb/delay/combo/mod/pitch/eq/dyn/enh/amp)
    public let heavy: Bool         // true = 仅 FX 1-4 (真台 DSP 限制)
    public let n: Int              // 参数个数
    public let params: [FxParamSpec]
    public let time: Int?          // 语义别名 → par 号 (混响时间, Tap/同步组用)
    public let predelay: Int?
    public let damp: Int?
    public let tmin: Double?       // 时间参数的量程 (Tap 换算钳制区间)
    public let tmax: Double?
    public let tunit: String?      // "s" 或 "ms" (GATE/RVRS 是毫秒)
}

/// 整套效果库 (JSON 的 Codable 映射)
public struct FxLib: Codable, Equatable, Sendable {
    public let version: Int
    public let source: String
    public let algos: [String: FxAlgoSpec]
    public let enum58: [String]        // FX 5-8 可装的轻量子集
    public let catLabel: [String: String]
    public let alias: [String: String] // 旧枚举名 → 新名 (PLATE→PLAT 等)

    public func algo(_ name: String) -> FxAlgoSpec? { algos[name] }

    /// 槽位能否装这个算法 (heavy 仅 FX 1-4)
    public func slotAllows(_ slot: Int, _ name: String) -> Bool {
        guard let a = algos[name] else { return false }
        if a.heavy && !(1...4).contains(slot) { return false }
        return true
    }

    public func paramSpec(_ algoName: String, _ field: String) -> FxParamSpec? {
        algo(algoName)?.params.first { $0.field == field }
    }

    /// field → par 号。三条路径与服务端 fx_field_par 一致:
    /// 算法 field / "parNN" 直址 / 语义别名 time·predelay·damp
    /// (形参不敢叫 algo: 会遮蔽同名方法 algo(_:), algo(algo) 直接编译不过)
    public func fieldToPar(_ algoName: String, _ field: String) -> Int? {
        guard let a = algo(algoName) else { return nil }
        if field.hasPrefix("par"), let n = Int(field.dropFirst(3)),
           a.params.contains(where: { $0.p == n }) { return n }
        if let p = a.params.first(where: { $0.field == field })?.p { return p }
        let aliasKey = ["time": a.time, "predelay": a.predelay, "damp": a.damp][field]
        return aliasKey ?? nil
    }

    /// 按分类分组的算法名 (下拉分组渲染用; 顺序 = 分类表顺序)
    public func algosByCategory() -> [(cat: String, label: String, names: [String])] {
        var groups: [String: [String]] = [:]
        for (name, a) in algos { groups[a.cat, default: []].append(name) }
        return catLabel.keys.compactMap { cat in
            guard let names = groups[cat], !names.isEmpty else { return nil }
            return (cat: cat, label: catLabel[cat] ?? cat, names: names.sorted())
        }
    }
}

// FxCalibration.json / FxCalibration.load() 由 export_fx_calibration.py 生成,
// 见 FxCalibration+Generated.swift (禁止手改)。

/// 全局访问点: 解码一次, 之后零成本
public enum FxCalibrationStore {
    public static let shared: FxLib? = FxCalibration.load()
}
