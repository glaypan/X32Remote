import Foundation

/// 写入来源标记。决定该次写入是否触发冲突检测（协议规范第 9 节）。
public enum WriteSource: String, Sendable {
    /// 用户手动操作（推子、按键）—— ✅ 会触发冲突检测
    case manual
    /// 卡片引擎自己的写入 —— ❌ 不触发
    case action
    /// DCA 级联产生的成员写入 —— ❌ 不触发
    case dca
    /// 从真台回读对齐本地状态 —— ❌ 不触发
    case sync

    public var triggersConflictCheck: Bool { self == .manual }
}

/// 台面写入/读取接口。
///
/// 时间轴调度器只依赖这个协议，因此可以在没有真实网络的情况下完整单测。
public protocol MixerWriting: AnyObject, Sendable {
    /// 写入一个推子行程 / 静音开关 / DCA 成员位掩码
    func writeValue(kind: String, idx: Int, value: Float, source: WriteSource)
    /// 发送原始 OSC（场景调用等）
    func writeRaw(address: String, args: [OscArgument])
    /// 读取当前推子行程（0..1）
    func readFader(kind: String, idx: Int) -> Float
    /// 冲突告警用的完整标签，如 `音乐(通道15)`
    func targetLabel(kind: String, idx: Int) -> String
}

/// 卡片执行进度（上报给 UI）
public struct EngineProgress: Equatable, Sendable {
    public var runningId: String?
    public var name: String
    public var progress: Float
    public var step: String

    public init(runningId: String? = nil, name: String = "", progress: Float = 0, step: String = "") {
        self.runningId = runningId
        self.name = name
        self.progress = progress
        self.step = step
    }

    public var isRunning: Bool { runningId != nil }
}

/// 演出卡片引擎（时间轴调度器）。
///
/// 与网页端 / 服务端逐项对齐：
///  - 12 种动作白名单 + 参数钳制（见 `CardAction`）
///  - 4 条曲线，50ms tick；`at` 偏移的动作**并行**执行
///  - 渐变起点在**触发瞬间**取当前值；`fade_from` 会先把推子置到 `frm`
///  - `next` 链式接续（防环：同一张卡片不重复、链长上限 16）
///  - **冲突策略**：手动干预只冻结被干预的那一路，其余动作与通道继续执行
public final class ShowEngine: @unchecked Sendable {

    public static let maxChainDepth = 16
    public static let tickSeconds: Float = 0.05

    private let mixer: MixerWriting
    private let lock = NSLock()

    /// 事件出口（冲突告警等），回调在主线程
    public var eventSink: ((String) -> Void)?
    /// 进度出口，回调在主线程
    public var progressSink: ((EngineProgress) -> Void)?

    private var _cards: [TimelineCard]
    private var _progress = EngineProgress()

    /// `"kind:idx"` → 正在驱动该路的卡片名
    private var fadeZone: [String: String] = [:]
    /// 本轮渐变中被手动接管的通道
    private var interrupts: Set<String> = []

    private var generation = 0
    private var stopFlag = false
    private var stopAfterChain = false
    private var runTask: Task<Void, Never>?

    public init(mixer: MixerWriting, cards: [TimelineCard] = TimelineCard.defaults()) {
        self.mixer = mixer
        self._cards = cards
    }

    // MARK: - 只读状态

    public var cards: [TimelineCard] {
        lock.lock(); defer { lock.unlock() }
        return _cards
    }

    public var progress: EngineProgress {
        lock.lock(); defer { lock.unlock() }
        return _progress
    }

    public func card(id: String) -> TimelineCard? {
        lock.lock(); defer { lock.unlock() }
        return _cards.first { $0.id == id }
    }

    public func setCards(_ cards: [TimelineCard]) {
        lock.lock(); _cards = cards; lock.unlock()
    }

    public func upsert(_ card: TimelineCard) {
        lock.lock()
        if let i = _cards.firstIndex(where: { $0.id == card.id }) {
            _cards[i] = card
        } else {
            _cards.append(card)
        }
        lock.unlock()
    }

    public func remove(id: String) {
        lock.lock()
        _cards.removeAll { $0.id == id }
        // 清掉指向已删除卡片的 next，避免链断在半路
        for i in 0..<_cards.count {
            if _cards[i].next == id { _cards[i].next = nil }
        }
        lock.unlock()
    }

    public func togglePin(id: String) {
        lock.lock()
        if let i = _cards.firstIndex(where: { $0.id == id }) {
            _cards[i].pinned.toggle()
        }
        lock.unlock()
    }

    // MARK: - 冲突策略

    /// 手动干预的来路。服务端对两种来路用不同措辞，这里保持一致。
    public enum TakeoverOrigin: Sendable {
        /// 手机上的操作（App 推子/按键）
        case local
        /// 真台面板上的操作（桥接回读时发现）
        case remote
    }

    /// 判定手动干预。**只冻结被干预的那一路**，卡片其余动作继续跑。
    ///
    /// 返回告警文案（无冲突时返回 nil）。由 `X32Client` 在任何
    /// `source == .manual` 的写入之前调用，也用于真台面板被改动时。
    ///
    /// 只冻结被碰的这一路，卡片其余通道与后续动作照常执行。
    @discardableResult
    public func checkManualTakeover(kind: String, idx: Int,
                                    origin: TakeoverOrigin = .local) -> String? {
        let k = ShowEngine.key(kind: kind, idx: idx)
        let zone: String
        lock.lock()
        guard let z = fadeZone[k], !interrupts.contains(k) else {
            lock.unlock()
            return nil
        }
        interrupts.insert(k)
        zone = z
        lock.unlock()

        let label = mixer.targetLabel(kind: kind, idx: idx)
        let text: String
        switch origin {
        case .local:
            text = "⚠️ \(label) 手动接管 — 卡片「\(zone)」停止驱动该通道，其余动作继续"
        case .remote:
            text = "⚠️ 真台上 \(label) 被手动干预 — 卡片「\(zone)」停止驱动该通道，其余动作继续"
        }
        emit(text)
        return text
    }

    /// 某一路当前是否正被卡片驱动（且未被接管），用于 UI 高亮
    public func isDriven(kind: String, idx: Int) -> Bool {
        let k = ShowEngine.key(kind: kind, idx: idx)
        lock.lock(); defer { lock.unlock() }
        return fadeZone[k] != nil && !interrupts.contains(k)
    }

    /// 当前是否有卡片在跑
    public var isRunning: Bool { progress.isRunning }

    private func isInterrupted(kind: String, idx: Int) -> Bool {
        let k = ShowEngine.key(kind: kind, idx: idx)
        lock.lock(); defer { lock.unlock() }
        return interrupts.contains(k)
    }

    private func registerFade(_ targets: [(kind: String, idx: Int, to: Float)], cardName: String) {
        lock.lock()
        for t in targets {
            let k = ShowEngine.key(kind: t.kind, idx: t.idx)
            interrupts.remove(k)
            fadeZone[k] = cardName
        }
        lock.unlock()
    }

    private func unregisterFade(_ targets: [(kind: String, idx: Int, to: Float)]) {
        lock.lock()
        for t in targets {
            fadeZone.removeValue(forKey: ShowEngine.key(kind: t.kind, idx: t.idx))
        }
        lock.unlock()
    }

    private func clearFadeZone() {
        lock.lock()
        fadeZone.removeAll()
        interrupts.removeAll()
        lock.unlock()
    }

    private static func key(kind: String, idx: Int) -> String { "\(kind):\(idx)" }

    // MARK: - 运行控制

    /// 启动卡片。若已有卡片在跑则先停掉。
    ///
    /// - Parameters:
    ///   - chainDepth: 链深，用于兜底防环（上限 `maxChainDepth`）
    ///   - visited: 本次链已执行过的卡片 id；命中即判循环并停止接续（与服务端一致）
    public func run(cardId: String, chainDepth: Int = 0, visited: Set<String> = []) {
        guard let card = card(id: cardId) else { return }
        if visited.contains(cardId) {
            emit("⚠️ 卡片链检测到循环（「\(card.name)」重复出现），已停止接续")
            setProgress(EngineProgress())
            return
        }
        if chainDepth > ShowEngine.maxChainDepth {
            emit("⚠️ 卡片链超过 \(ShowEngine.maxChainDepth) 层，已中止（疑似循环）")
            return
        }
        stopAll()
        let gen = beginRun()
        let seen = visited.union([cardId])
        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runCard(card, chainDepth: chainDepth, visited: seen, generation: gen)
        }
    }

    /// 停止当前卡片（不再接续下一张）
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopFlag = true
    }

    /// 停止整条卡片链并清空驱动区
    public func stopAll() {
        lock.lock()
        stopFlag = true
        stopAfterChain = true
        generation += 1          // 让在跑的循环立即失效
        runTask?.cancel()
        runTask = nil
        lock.unlock()
        clearFadeZone()
        setProgress(EngineProgress())
    }

    private func beginRun() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        stopFlag = false
        stopAfterChain = false
        return generation
    }

    private func isActive(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == gen && !stopFlag
    }

    private var shouldStopAfterChain: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopAfterChain
    }

    // MARK: - 时间轴

    private final class TimelineEntry {
        let action: CardAction
        let number: Int
        var start: Float
        var duration: Float
        var targets: [(kind: String, idx: Int, to: Float)] = []
        var fired = false
        var isActive = false

        init(action: CardAction, number: Int, start: Float, duration: Float) {
            self.action = action
            self.number = number
            self.start = start
            self.duration = duration
        }

        var hasTargets: Bool { !targets.isEmpty }
    }

    private struct ActiveFade {
        let targets: [(kind: String, idx: Int, to: Float)]
        let starts: [(kind: String, idx: Int, from: Float)]
    }

    /// 时间轴排布：无 `at` 的动作顺序排布，有 `at` 的按其偏移并行。
    ///
    /// 注意 cursor 的推进规则与服务端一致：**每个动作都会把 cursor 推到自己的结束时刻**
    /// （因此带 `at` 的动作也会把后续顺序动作顺延到它之后）。
    public func buildTimeline(_ card: TimelineCard) -> [(start: Float, duration: Float, label: String, isParallel: Bool)] {
        var out: [(Float, Float, String, Bool)] = []
        var cursor: Float = 0
        for (n, a) in card.actions.enumerated() {
            let start = a.isParallel ? a.at : cursor
            let dur = a.occupiesSeconds
            out.append((start, dur, "#\(n + 1) \(a.shortName)", a.isParallel))
            cursor = start + dur
        }
        return out
    }

    private func makeEntries(_ card: TimelineCard) -> [TimelineEntry] {
        var out: [TimelineEntry] = []
        var cursor: Float = 0
        for (n, a) in card.actions.enumerated() {
            let start = a.isParallel ? a.at : cursor
            let dur = a.occupiesSeconds
            let e = TimelineEntry(action: a, number: n, start: start, duration: dur)
            e.targets = fadeTargets(for: a)
            out.append(e)
            cursor = start + dur
        }
        return out
    }

    /// 渐变动作 → 目标列表；非渐变返回空
    func fadeTargets(for a: CardAction) -> [(kind: String, idx: Int, to: Float)] {
        switch a.kind {
        case "fade_all":
            var out: [(String, Int, Float)] = []
            for i in 1...32 { out.append(("ch_fader", i, a.to)) }
            for i in 1...16 { out.append(("bus_fader", i, a.to)) }
            for i in 1...8 { out.append(("dca_fader", i, a.to)) }
            for i in 1...6 { out.append(("auxin_fader", i, a.to)) }
            for i in 1...2 { out.append(("usb_fader", i, a.to)) }
            for i in 1...8 { out.append(("fxret_fader", i, a.to)) }
            for i in 1...6 { out.append(("mtx_fader", i, a.to)) }
            out.append(("main_fader", 0, a.to))
            return out

        case "fade_odd_even":
            return (1...32).map { ("ch_fader", $0, $0 % 2 == 1 ? a.oddTo : a.evenTo) }

        case "fade_ch":
            return a.chs.map { ("ch_fader", $0, a.to) }

        case "fade_bus":
            return a.buses.map { ("bus_fader", $0, a.to) }

        case "fade_from":
            return [("ch_fader", a.singleCh, a.to)]

        case "fade_from_bus":
            return [("bus_fader", a.singleBus, a.to)]

        case "rel_db":
            // 相对 dB：执行瞬间按当前推子位置换算
            guard let fk = a.faderKind else { return [] }
            return a.relDbTargets.map { i in
                let curDb = MixerSpec.faderToDb(mixer.readFader(kind: fk, idx: i))
                let target = MixerSpec.dbToFader(min(max(curDb + a.deltaDb, -90), 10))
                return (fk, i, target)
            }

        default:
            return []
        }
    }

    // MARK: - 执行

    private func runCard(_ card: TimelineCard, chainDepth: Int, visited: Set<String>, generation gen: Int) async {
        // All Live 电动推子演示（与服务端同一套正弦，整段 12 秒）
        if card.id == "alllive" {
            await runAllLiveDemo(card, generation: gen)
            guard isActive(gen) else {
                setProgress(EngineProgress())
                return
            }
            await finishChain(card, chainDepth: chainDepth, visited: visited, generation: gen)
            return
        }

        let entries = makeEntries(card)
        guard !entries.isEmpty else {
            await finishChain(card, chainDepth: chainDepth, visited: visited, generation: gen)
            return
        }

        let total = max(entries.map { $0.start + $0.duration }.max() ?? 0, 0.001)
        setProgress(EngineProgress(runningId: card.id, name: card.name, progress: 0, step: ""))

        let t0 = DispatchTime.now().uptimeNanoseconds
        var active: [Int: ActiveFade] = [:]

        while isActive(gen) {
            let t = ShowEngine.elapsed(since: t0)

            for e in entries {
                if t < e.start { continue }

                if !e.fired {
                    e.fired = true
                    setStep(card: card, entry: e, totalActions: entries.count)

                    if e.duration <= 0.001 {
                        execInstant(e.action)
                        continue
                    }
                    guard e.hasTargets else {
                        execInstant(e.action)     // wait：占用时长但不驱动推子
                        continue
                    }
                    // fade_from 语义：先把推子置到指定起点，再以此为渐变起点
                    if e.action.kind == "fade_from" || e.action.kind == "fade_from_bus",
                       let first = e.targets.first {
                        mixer.writeValue(kind: first.kind, idx: first.idx, value: e.action.frm, source: .action)
                    }
                    let starts = e.targets.map {
                        (kind: $0.kind, idx: $0.idx, from: mixer.readFader(kind: $0.kind, idx: $0.idx))
                    }
                    registerFade(e.targets, cardName: card.name)
                    active[e.number] = ActiveFade(targets: e.targets, starts: starts)
                    e.isActive = true
                }

                guard let a = active[e.number] else { continue }
                if t >= e.start + e.duration {
                    applyFade(a, ratio: 1)
                    unregisterFade(a.targets)
                    active.removeValue(forKey: e.number)
                    e.isActive = false
                } else if e.duration > 0.001 {
                    let ratio = MixerSpec.applyCurve((t - e.start) / e.duration, e.action.curve)
                    applyFade(a, ratio: ratio)
                }
            }

            if active.isEmpty, entries.allSatisfy({ $0.fired }),
               t >= total - ShowEngine.tickSeconds {
                break
            }

            setProgressValue(min(1, t / total), card: card)
            try? await Task.sleep(nanoseconds: UInt64(ShowEngine.tickSeconds * 1_000_000_000))
        }

        // 停止：渐变就地冻结在当前值，不写终值
        for a in active.values { unregisterFade(a.targets) }

        guard isActive(gen) else {
            setProgress(EngineProgress())
            return
        }
        await finishChain(card, chainDepth: chainDepth, visited: visited, generation: gen)
    }

    /// 渐变推进：逐路累加，已被接管的通道跳过
    private func applyFade(_ a: ActiveFade, ratio: Float) {
        for (i, target) in a.targets.enumerated() {
            guard i < a.starts.count else { continue }
            if isInterrupted(kind: target.kind, idx: target.idx) { continue }
            let from = a.starts[i].from
            let v = from + (target.to - from) * ratio
            mixer.writeValue(kind: target.kind, idx: target.idx, value: v, source: .action)
        }
    }

    /// 瞬时动作：静音 / 静音 Bus / 切场景 / 全部取消静音 / 等待
    private func execInstant(_ a: CardAction) {
        switch a.kind {
        case "mute":
            for c in a.chs { mixer.writeValue(kind: "ch_on", idx: c, value: 0, source: .action) }
        case "mute_bus":
            for b in a.buses { mixer.writeValue(kind: "bus_on", idx: b, value: 0, source: .action) }
        case "unmute_all":
            // 与服务端一致：ch / bus / dca / auxin / usb / fxret / mtx / main 全部取消静音
            for i in 1...32 { mixer.writeValue(kind: "ch_on", idx: i, value: 1, source: .action) }
            for i in 1...16 { mixer.writeValue(kind: "bus_on", idx: i, value: 1, source: .action) }
            for i in 1...8 { mixer.writeValue(kind: "dca_on", idx: i, value: 1, source: .action) }
            for i in 1...6 { mixer.writeValue(kind: "auxin_on", idx: i, value: 1, source: .action) }
            for i in 1...2 { mixer.writeValue(kind: "usb_on", idx: i, value: 1, source: .action) }
            for i in 1...8 { mixer.writeValue(kind: "fxret_on", idx: i, value: 1, source: .action) }
            for i in 1...6 { mixer.writeValue(kind: "mtx_on", idx: i, value: 1, source: .action) }
            mixer.writeValue(kind: "main_on", idx: 0, value: 1, source: .action)
        case "scene":
            mixer.writeRaw(address: MixerSpec.sceneLoad(a.scene), args: [])
        case "wait":
            // 故意什么都不做。wait 的等待效果完全由时间轴偏移提供
            // （cursor 会把后续顺序动作的 start 推到 wait 结束之后），
            // 这里若再 sleep 一次就是双重计时：不仅总时长翻倍，
            // 还会在 sleep 期间冻结 tick 循环，把并行动作和正在跑的渐变一起卡住。
            // 服务端 _exec_instant 同样没有 wait 分支。
            break
        default:
            break
        }
    }

    /// All Live：前 8 路推子随"节奏"自动起伏 12 秒，结束后归位
    private func runAllLiveDemo(_ card: TimelineCard, generation gen: Int) async {
        let duration: Float = 12
        let base = (1...8).map { mixer.readFader(kind: "ch_fader", idx: $0) }
        let targets = (1...8).map { ("ch_fader", $0, Float(0)) }
        registerFade(targets, cardName: card.name)
        setProgress(EngineProgress(runningId: card.id, name: card.name, progress: 0, step: "All Live 推子起舞"))

        let t0 = DispatchTime.now().uptimeNanoseconds
        while isActive(gen) {
            let t = ShowEngine.elapsed(since: t0)
            if t >= duration { break }
            try? await Task.sleep(nanoseconds: 80_000_000)
            for i in 1...8 where !isInterrupted(kind: "ch_fader", idx: i) {
                let v = base[i - 1]
                    + 0.20 * sin(t * 2.4 + Float(i) * 0.85) * sin(t * 0.7)
                mixer.writeValue(kind: "ch_fader", idx: i, value: v, source: .action)
            }
            setProgressValue(min(1, t / duration), card: card)
        }
        // 归位（被接管的通道不动）
        for i in 1...8 where !isInterrupted(kind: "ch_fader", idx: i) {
            mixer.writeValue(kind: "ch_fader", idx: i, value: base[i - 1], source: .action)
        }
        unregisterFade(targets)
    }

    private func finishChain(_ card: TimelineCard, chainDepth: Int, visited: Set<String>,
                             generation gen: Int) async {
        guard !shouldStopAfterChain,
              let nxt = card.next, !nxt.isEmpty, nxt != card.id,
              self.card(id: nxt) != nil else {
            setProgress(EngineProgress())
            return
        }
        setProgress(EngineProgress(runningId: card.id, name: card.name, progress: 1))
        // 卡片之间留 0.4 秒喘息（对齐服务端 time.sleep(0.4)），
        // 让台面与界面都看清楚一次切换；期间被停止则不再接续。
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard isActive(gen), !shouldStopAfterChain else {
            setProgress(EngineProgress())
            return
        }
        run(cardId: nxt, chainDepth: chainDepth + 1, visited: visited)
    }

    // MARK: - 进度与事件

    private func setStep(card: TimelineCard, entry: TimelineEntry, totalActions: Int) {
        let text = "\(entry.number + 1)/\(totalActions) · \(actionLabel(entry.action))"
        let done = min(max(progress.progress, 0), 1)
        setProgress(EngineProgress(runningId: card.id, name: card.name, progress: done, step: text))
    }

    /// 只推进进度条，保留当前 step 文案（与服务端一致，step 不会一闪而过）
    private func setProgressValue(_ value: Float, card: TimelineCard) {
        lock.lock()
        let step = _progress.step
        lock.unlock()
        setProgress(EngineProgress(runningId: card.id, name: card.name,
                                   progress: min(max(value, 0), 1), step: step))
    }

    private func setProgress(_ p: EngineProgress) {
        lock.lock()
        _progress = p
        lock.unlock()
        guard let sink = progressSink else { return }
        DispatchQueue.main.async { sink(p) }
    }

    private func emit(_ text: String) {
        guard let sink = eventSink else { return }
        DispatchQueue.main.async { sink(text) }
    }

    /// 动作描述（供 UI 与进度文案复用）
    public func actionLabel(_ a: CardAction) -> String {
        a.label { kind, idx in mixer.targetLabel(kind: kind, idx: idx) }
    }

    private static func elapsed(since t0: UInt64) -> Float {
        Float(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000)
    }
}
