import Foundation

/// 演出卡片的一条动作。
///
/// **JSON 格式与服务端 `user_config.json` / 网页端卡片编辑器逐字段一致**，
/// 因此手机上的卡片可以直接导出给电脑用，反之亦然。
///
/// 12 种动作白名单、参数钳制区间、默认值全部对齐
/// `x32_simulator.py` 的 `clean_action()` 与 Android 的 `ShowEngine.cleanAction()`。
public struct CardAction: Codable, Equatable, Sendable, Identifiable {

    /// 动作白名单（仅这 12 种，其余一律拒绝）
    public static let kinds = [
        "mute", "mute_bus", "scene", "unmute_all", "wait",
        "fade_all", "fade_odd_even", "fade_ch", "fade_bus",
        "fade_from", "fade_from_bus", "rel_db",
    ]

    /// 渐变类动作（占用时长为 duration，起点在触发瞬间取当前值）
    public static let fadeKinds: Set<String> = [
        "fade_all", "fade_odd_even", "fade_ch", "fade_bus",
        "fade_from", "fade_from_bus", "rel_db",
    ]

    public var kind: String = ""
    public var chs: [Int] = []
    public var buses: [Int] = []
    public var dcas: [Int] = []
    public var scene: Int = 1
    public var to: Float = 0.8
    public var frm: Float = 0
    public var oddTo: Float = 0.8
    public var evenTo: Float = 0
    public var duration: Float = 3
    public var curve: String = "linear"
    public var deltaDb: Float = 3
    public var group: String = "ch"

    /// 时间轴偏移（秒）；`-1` 表示"接在上一个动作之后顺序执行"。
    /// 给了 `at` 的动作与其它动作**并行**。
    public var at: Float = -1

    public var singleCh: Int = 1
    public var singleBus: Int = 1

    /// 仅本地 UI 使用，不参与 JSON 交换
    public var id: String = UUID().uuidString

    public init(kind: String,
                chs: [Int] = [],
                buses: [Int] = [],
                dcas: [Int] = [],
                scene: Int = 1,
                to: Float = 0.8,
                frm: Float = 0,
                oddTo: Float = 0.8,
                evenTo: Float = 0,
                duration: Float = 3,
                curve: String = "linear",
                deltaDb: Float = 3,
                group: String = "ch",
                at: Float = -1,
                singleCh: Int = 1,
                singleBus: Int = 1,
                id: String = UUID().uuidString) {
        self.kind = kind
        self.chs = chs
        self.buses = buses
        self.dcas = dcas
        self.scene = scene
        self.to = to
        self.frm = frm
        self.oddTo = oddTo
        self.evenTo = evenTo
        self.duration = duration
        self.curve = curve
        self.deltaDb = deltaDb
        self.group = group
        self.at = at
        self.singleCh = singleCh
        self.singleBus = singleBus
        self.id = id
    }

    // MARK: - 派生属性

    public var isFade: Bool { CardAction.fadeKinds.contains(kind) }

    /// 该动作在时间轴上占用的秒数（瞬时动作占 0）
    public var occupiesSeconds: Float {
        switch kind {
        case "wait":   return min(max(duration, 0.5), 60)
        case _ where isFade: return max(duration, 0.5)
        default:       return 0
        }
    }

    /// 是否设置了并行时间轴偏移
    public var isParallel: Bool { at >= 0 }

    /// 受该动作影响的推子 kind（`rel_db` 按 group 决定；非渐变返回 nil）
    public var faderKind: String? {
        switch kind {
        case "fade_all", "fade_odd_even", "fade_ch", "fade_from": return "ch_fader"
        case "fade_bus", "fade_from_bus": return "bus_fader"
        case "rel_db":
            switch group {
            case "bus": return "bus_fader"
            case "dca": return "dca_fader"
            default:    return "ch_fader"
            }
        default:
            return nil
        }
    }

    /// `rel_db` 的目标编号列表
    public var relDbTargets: [Int] {
        switch group {
        case "bus": return buses
        case "dca": return dcas
        default:    return chs
        }
    }

    // MARK: - 展示文案

    /// 生成动作描述。`name` 由调用方提供（需要台面状态才能拿到通道名）。
    public func label(name: (String, Int) -> String) -> String {
        switch kind {
        case "mute":
            return "静音 " + chs.map { name("ch_on", $0) }.joined(separator: "、")
        case "mute_bus":
            return "静音 " + buses.map { name("bus_on", $0) }.joined(separator: "、")
        case "scene":
            return "切场景 \(scene)"
        case "unmute_all":
            return "全部取消静音"
        case "wait":
            return String(format: "等待 %.0f 秒", duration)
        case "fade_all":
            return String(format: "全体推子 →%.0f%%", to * 100)
        case "fade_odd_even":
            return String(format: "奇偶过渡 奇→%.0f%% 偶→%.0f%%", oddTo * 100, evenTo * 100)
        case "fade_ch":
            return chs.map { name("ch_fader", $0) }.joined(separator: "、")
                + String(format: " →%.0f%%", to * 100)
        case "fade_bus":
            return buses.map { name("bus_fader", $0) }.joined(separator: "、")
                + String(format: " →%.0f%%", to * 100)
        case "fade_from":
            return String(format: "%@ %.0f→%.0f%%", name("ch_fader", singleCh), frm * 100, to * 100)
        case "fade_from_bus":
            return String(format: "%@ %.0f→%.0f%%", name("bus_fader", singleBus), frm * 100, to * 100)
        case "rel_db":
            let sign = deltaDb >= 0 ? "+" : "−"
            return relDbTargets.map { name("\(group)_fader", $0) }.joined(separator: "、")
                + String(format: " %@%.1f dB", sign, abs(deltaDb))
        default:
            return kind
        }
    }

    /// 短名（用于时间轴表格的"类型"列）
    public var shortName: String {
        switch kind {
        case "mute":          return "静音通道"
        case "mute_bus":      return "静音 Bus"
        case "scene":         return "切场景"
        case "unmute_all":    return "全部取消静音"
        case "wait":          return "等待"
        case "fade_all":      return "全体渐变"
        case "fade_odd_even": return "奇偶过渡"
        case "fade_ch":       return "通道渐变"
        case "fade_bus":      return "Bus 渐变"
        case "fade_from":     return "通道指定起点渐变"
        case "fade_from_bus": return "Bus 指定起点渐变"
        case "rel_db":        return "相对 ±dB"
        default:              return kind
        }
    }

    public var icon: String {
        switch kind {
        case "mute":          return "mic.slash"
        case "mute_bus":      return "speaker.slash"
        case "scene":         return "square.3.layers.3d"
        case "unmute_all":    return "speaker.wave.2"
        case "wait":          return "timer"
        case "fade_all":      return "slider.horizontal.below.rectangle"
        case "fade_odd_even": return "arrow.left.arrow.right"
        case "fade_ch":       return "slider.horizontal.3"
        case "fade_bus":      return "arrowshape.turn.up.right"
        case "fade_from":     return "slider.horizontal.3"
        case "fade_from_bus": return "arrowshape.turn.up.right"
        case "rel_db":        return "plusminus.circle"
        default:              return "questionmark"
        }
    }

    // MARK: - 工厂

    /// 新建动作的默认参数（与 `clean_action()` 的兜底值一致）
    public static func new(kind: String) -> CardAction {
        switch kind {
        case "mute":      return CardAction(kind: kind, chs: [1])
        case "mute_bus":  return CardAction(kind: kind, buses: [1])
        case "scene":     return CardAction(kind: kind, scene: 1)
        case "unmute_all": return CardAction(kind: kind)
        case "wait":      return CardAction(kind: kind, duration: 1)
        case "fade_all":
            return CardAction(kind: kind, to: 0, duration: 3, curve: "linear")
        case "fade_odd_even":
            return CardAction(kind: kind, oddTo: 0.8, evenTo: 0, duration: 4, curve: "linear")
        case "fade_ch":
            return CardAction(kind: kind, chs: [1], to: 0.8, duration: 3, curve: "linear")
        case "fade_bus":
            return CardAction(kind: kind, buses: [1], to: 0.8, duration: 3, curve: "linear")
        case "fade_from":
            return CardAction(kind: kind, to: 0.9, frm: 0, duration: 5, curve: "linear", singleCh: 1)
        case "fade_from_bus":
            return CardAction(kind: kind, to: 0.9, frm: 0, duration: 5, curve: "linear", singleBus: 1)
        case "rel_db":
            return CardAction(kind: kind, chs: [1], duration: 2, curve: "linear", deltaDb: 3, group: "ch")
        default:
            return CardAction(kind: kind)
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind, chs, ch, buses, bus, dcas, dca, scene, to, frm
        case oddTo = "odd_to"
        case evenTo = "even_to"
        case duration, curve
        case deltaDb = "delta_db"
        case group, at
    }

    private static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let d = try? c.decode(Double.self, forKey: key), d.isFinite { return d }
        if let i = try? c.decode(Int.self, forKey: key) { return Double(i) }
        return nil
    }

    private static func float(_ c: KeyedDecodingContainer<CodingKeys>,
                              _ key: CodingKeys,
                              _ fallback: Float,
                              _ lo: Float,
                              _ hi: Float) -> Float {
        guard let d = number(c, key) else { return fallback }
        return min(max(Float(d), lo), hi)
    }

    private static func integer(_ c: KeyedDecodingContainer<CodingKeys>,
                                _ key: CodingKeys,
                                _ fallback: Int,
                                _ lo: Int,
                                _ hi: Int) -> Int {
        guard let d = number(c, key) else { return fallback }
        return min(max(Int(d.rounded()), lo), hi)
    }

    /// 接受数组（`chs: [1,2]`）或旧式单值（`ch: 1`）；去重、排序、钳制，空则兜底为下界
    private static func ids(_ c: KeyedDecodingContainer<CodingKeys>,
                            _ listKey: CodingKeys,
                            _ singleKey: CodingKeys?,
                            _ lo: Int,
                            _ hi: Int) -> [Int] {
        var out = Set<Int>()
        if let arr = try? c.decode([Double].self, forKey: listKey) {
            for d in arr where d.isFinite {
                out.insert(min(max(Int(d.rounded()), lo), hi))
            }
        }
        if out.isEmpty, let singleKey, let d = number(c, singleKey) {
            out.insert(min(max(Int(d.rounded()), lo), hi))
        }
        return out.isEmpty ? [lo] : out.sorted()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        guard CardAction.kinds.contains(rawKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "未知动作类型：\(rawKind)")
        }
        self.kind = rawKind
        self.curve = (try? c.decode(String.self, forKey: .curve))
            .flatMap { MixerSpec.curves.contains($0) ? $0 : nil } ?? "linear"
        self.at = c.contains(.at) ? CardAction.float(c, .at, 0, 0, 600) : -1

        switch rawKind {
        case "mute":
            self.chs = CardAction.ids(c, .chs, .ch, 1, 32)
        case "mute_bus":
            self.buses = CardAction.ids(c, .buses, .bus, 1, 16)
        case "scene":
            self.scene = CardAction.integer(c, .scene, 1, 1, 99)
        case "unmute_all":
            break
        case "wait":
            self.duration = CardAction.float(c, .duration, 1, 0.5, 60)
        case "fade_all":
            self.to = CardAction.float(c, .to, 0, 0, 1)
            self.duration = CardAction.float(c, .duration, 3, 0.5, 30)
        case "fade_odd_even":
            self.oddTo = CardAction.float(c, .oddTo, 0.8, 0, 1)
            self.evenTo = CardAction.float(c, .evenTo, 0, 0, 1)
            self.duration = CardAction.float(c, .duration, 4, 0.5, 30)
        case "fade_ch":
            self.chs = CardAction.ids(c, .chs, .ch, 1, 32)
            self.to = CardAction.float(c, .to, 0.8, 0, 1)
            self.duration = CardAction.float(c, .duration, 3, 0.5, 30)
        case "fade_bus":
            self.buses = CardAction.ids(c, .buses, .bus, 1, 16)
            self.to = CardAction.float(c, .to, 0.8, 0, 1)
            self.duration = CardAction.float(c, .duration, 3, 0.5, 30)
        case "fade_from":
            self.singleCh = CardAction.integer(c, .ch, 1, 1, 32)
            self.frm = CardAction.float(c, .frm, 0, 0, 1)
            self.to = CardAction.float(c, .to, 0.9, 0, 1)
            self.duration = CardAction.float(c, .duration, 5, 0.5, 30)
        case "fade_from_bus":
            self.singleBus = CardAction.integer(c, .bus, 1, 1, 16)
            self.frm = CardAction.float(c, .frm, 0, 0, 1)
            self.to = CardAction.float(c, .to, 0.9, 0, 1)
            self.duration = CardAction.float(c, .duration, 5, 0.5, 30)
        case "rel_db":
            let g = (try? c.decode(String.self, forKey: .group)) ?? "ch"
            self.group = ["ch", "bus", "dca"].contains(g) ? g : "ch"
            let cap: Int
            switch self.group {
            case "bus": cap = 16
            case "dca": cap = 8
            default:    cap = 32
            }
            switch self.group {
            case "bus": self.buses = CardAction.ids(c, .buses, .bus, 1, cap)
            case "dca": self.dcas = CardAction.ids(c, .dcas, .dca, 1, cap)
            default:    self.chs = CardAction.ids(c, .chs, .ch, 1, cap)
            }
            self.deltaDb = CardAction.float(c, .deltaDb, 3, -30, 30)
            self.duration = CardAction.float(c, .duration, 2, 0.5, 30)
        default:
            break
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        if !chs.isEmpty { try c.encode(chs, forKey: .chs) }
        if !buses.isEmpty { try c.encode(buses, forKey: .buses) }
        if !dcas.isEmpty { try c.encode(dcas, forKey: .dcas) }

        switch kind {
        case "scene":
            try c.encode(scene, forKey: .scene)
        case "wait":
            try c.encode(duration, forKey: .duration)
        case "fade_all", "fade_ch", "fade_bus":
            try c.encode(to, forKey: .to)
            try c.encode(duration, forKey: .duration)
            try c.encode(curve, forKey: .curve)
        case "fade_odd_even":
            try c.encode(oddTo, forKey: .oddTo)
            try c.encode(evenTo, forKey: .evenTo)
            try c.encode(duration, forKey: .duration)
            try c.encode(curve, forKey: .curve)
        case "fade_from":
            try c.encode(singleCh, forKey: .ch)
            try c.encode(frm, forKey: .frm)
            try c.encode(to, forKey: .to)
            try c.encode(duration, forKey: .duration)
            try c.encode(curve, forKey: .curve)
        case "fade_from_bus":
            try c.encode(singleBus, forKey: .bus)
            try c.encode(frm, forKey: .frm)
            try c.encode(to, forKey: .to)
            try c.encode(duration, forKey: .duration)
            try c.encode(curve, forKey: .curve)
        case "rel_db":
            try c.encode(group, forKey: .group)
            try c.encode(deltaDb, forKey: .deltaDb)
            try c.encode(duration, forKey: .duration)
            try c.encode(curve, forKey: .curve)
        default:
            break
        }

        if at >= 0 { try c.encode(at, forKey: .at) }
    }
}

// MARK: - 卡片

/// 一张演出卡片（时间轴编排单元）。
public struct TimelineCard: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var desc: String
    public var actions: [CardAction]
    public var pinned: Bool

    /// 链式接续：本卡片结束后自动启动的下一张卡片 id（空 = 不接续）
    public var next: String?

    public init(id: String,
                name: String,
                desc: String = "",
                actions: [CardAction] = [],
                pinned: Bool = false,
                next: String? = nil) {
        self.id = id
        self.name = name
        self.desc = desc
        self.actions = actions
        self.pinned = pinned
        self.next = next
    }

    /// 时间轴总时长（秒）
    public var totalSeconds: Float {
        var cursor: Float = 0
        var maxEnd: Float = 0
        for a in actions {
            let start = a.isParallel ? a.at : cursor
            let end = start + a.occupiesSeconds
            if !a.isParallel { cursor = end }
            maxEnd = max(maxEnd, end)
        }
        return max(maxEnd, 0.05)
    }

    /// 卡片是否使用了并行时间轴（UI 上给个标记）
    public var hasParallelActions: Bool { actions.contains { $0.isParallel } }

    private enum CodingKeys: String, CodingKey {
        case id, name, desc, actions, pinned, next
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.name = (try? c.decode(String.self, forKey: .name)) ?? "未命名"
        self.desc = (try? c.decode(String.self, forKey: .desc)) ?? ""
        self.actions = (try? c.decode([CardAction].self, forKey: .actions)) ?? []
        self.pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        let n = (try? c.decode(String.self, forKey: .next)) ?? ""
        self.next = n.isEmpty ? nil : n
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        if !desc.isEmpty { try c.encode(desc, forKey: .desc) }
        try c.encode(pinned, forKey: .pinned)
        if let next, !next.isEmpty { try c.encode(next, forKey: .next) }
        try c.encode(actions, forKey: .actions)
    }

    // MARK: - 出厂卡片（与网页端 / Android 端同一套）

    public static func defaults() -> [TimelineCard] {
        [
            TimelineCard(
                id: "dinner", name: "🍽 晚宴模式",
                desc: "静音话筒 01/02 → 音乐(15) 10 秒渐弱到 30%",
                actions: [
                    CardAction(kind: "mute", chs: [1]),
                    CardAction(kind: "mute", chs: [2]),
                    CardAction(kind: "fade_ch", chs: [15], to: 0.30, duration: 10, curve: "linear"),
                ]),
            TimelineCard(
                id: "speech", name: "🎤 演讲模式",
                desc: "切场景 2 → 音乐静音 → 话筒(01) 3 秒渐强到 90%",
                actions: [
                    CardAction(kind: "scene", scene: 2),
                    CardAction(kind: "mute", chs: [15]),
                    CardAction(kind: "fade_ch", chs: [1], to: 0.90, duration: 3, curve: "linear"),
                ]),
            TimelineCard(
                id: "leave", name: "🚪 散场模式",
                desc: "全部取消静音 → 音乐(15) 5 秒渐强到 90%",
                actions: [
                    CardAction(kind: "unmute_all"),
                    CardAction(kind: "fade_from", to: 0.90, frm: 0, duration: 5,
                               curve: "linear", singleCh: 15),
                ]),
            TimelineCard(
                id: "alllive", name: "🎵 All Live 演示",
                desc: "前 8 路推子随节奏自动起伏（多段接力）",
                actions: [
                    CardAction(kind: "fade_ch", chs: Array(1...8), to: 0.9, duration: 1.5, curve: "smooth"),
                    CardAction(kind: "fade_ch", chs: Array(1...8), to: 0.45, duration: 1.5, curve: "smooth"),
                    CardAction(kind: "fade_ch", chs: Array(1...8), to: 0.85, duration: 1.5, curve: "smooth"),
                    CardAction(kind: "fade_ch", chs: Array(1...8), to: 0.5, duration: 1.5, curve: "smooth"),
                ]),
            TimelineCard(
                id: "sync_down", name: "⏬ 全体推下 (3秒)",
                desc: "全部推子 3 秒同步拉到底，先快后慢收尾",
                actions: [CardAction(kind: "fade_all", to: 0, duration: 3, curve: "ease_out")]),
            TimelineCard(
                id: "sync_up", name: "⏫ 全体拉回 (3秒)",
                desc: "全部推子 3 秒平滑拉回 0 dB，S 形缓入缓出",
                actions: [CardAction(kind: "fade_all", to: 0.75, duration: 3, curve: "smooth")]),
            TimelineCard(
                id: "odd_even", name: "🎸 歌曲过渡 (基数进偶数出)",
                desc: "奇数通道渐入到 80%，偶数通道同时渐出",
                actions: [CardAction(kind: "fade_odd_even", oddTo: 0.8, evenTo: 0, duration: 4)]),
            TimelineCard(
                id: "odd_even_back", name: "🎹 休息过渡 (偶数进基数出)",
                desc: "偶数通道渐入到 80%，奇数通道同时渐出",
                actions: [CardAction(kind: "fade_odd_even", oddTo: 0, evenTo: 0.8, duration: 4)]),
            // 演示时间轴并行与卡片链
            TimelineCard(
                id: "parallel_demo", name: "⏱ 并行时间轴演示",
                desc: "0s 话筒渐入、2s 音乐渐出 —— 两条渐变叠加进行（at 并行）",
                actions: [
                    CardAction(kind: "fade_ch", chs: [1], to: 0.9, duration: 6, curve: "smooth"),
                    CardAction(kind: "fade_ch", chs: [15], to: 0.2, duration: 6, curve: "ease_out", at: 2),
                ],
                next: "rel_db_demo"),
            TimelineCard(
                id: "rel_db_demo", name: "📈 相对 +3dB 补声",
                desc: "执行瞬间按当前推子位置整体抬高 3dB",
                actions: [
                    CardAction(kind: "rel_db", chs: [1, 2, 3, 4],
                               duration: 2, curve: "smooth", deltaDb: 3, group: "ch"),
                ]),
        ]
    }
}
