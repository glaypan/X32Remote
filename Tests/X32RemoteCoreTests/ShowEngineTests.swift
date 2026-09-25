import XCTest
@testable import X32RemoteCore

// MARK: - 假台面

/// 记录式台面：同时充当"本地虚拟台面"，便于断言卡片引擎的写入序列。
final class MockMixer: MixerWriting, @unchecked Sendable {
    struct Write: Equatable {
        let kind: String
        let idx: Int
        let value: Float
        let source: WriteSource
    }

    private let lock = NSLock()
    private var _state: RemoteState
    private var _writes: [Write] = []
    private var _raws: [String] = []

    init(state: RemoteState = RemoteState()) {
        self._state = state
    }

    func writeValue(kind: String, idx: Int, value: Float, source: WriteSource) {
        lock.lock()
        _writes.append(Write(kind: kind, idx: idx, value: value, source: source))
        switch kind {
        case "ch_dca":
            _state.setDcaMask(ofChannel: idx, to: Int(value))
        case _ where kind.hasSuffix("_on"):
            _state.setOn(kind: kind, idx: idx, to: value != 0)
        default:
            _state.setFader(kind: kind, idx: idx, to: value)
        }
        lock.unlock()
    }

    func writeRaw(address: String, args: [OscArgument]) {
        lock.lock(); _raws.append(address); lock.unlock()
    }

    func readFader(kind: String, idx: Int) -> Float {
        lock.lock(); defer { lock.unlock() }
        return _state.fader(kind: kind, idx: idx)
    }

    func targetLabel(kind: String, idx: Int) -> String { "\(kind)#\(idx)" }

    // 测试辅助

    var writes: [Write] {
        lock.lock(); defer { lock.unlock() }
        return _writes
    }

    var rawAddresses: [String] {
        lock.lock(); defer { lock.unlock() }
        return _raws
    }

    func setInitialFader(kind: String, idx: Int, to value: Float) {
        lock.lock(); _state.setFader(kind: kind, idx: idx, to: value); lock.unlock()
    }

    func reset() {
        lock.lock(); _writes.removeAll(); _raws.removeAll(); lock.unlock()
    }
}

private func makeEngine(_ mixer: MockMixer, _ cards: [TimelineCard] = []) -> ShowEngine {
    ShowEngine(mixer: mixer, cards: cards)
}

/// 线程安全的事件收集器（引擎回调在主线程，测试在后台线程读）
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ text: String) {
        lock.lock(); items.append(text); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

/// 轮询等待条件成立（比基于进度回调的等待更稳：detached 任务的启动时刻不确定）
@discardableResult
private func waitUntil(_ timeout: TimeInterval = 6,
                       _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// 等引擎真正进入运行态后再等它跑完
private func waitIdle(_ engine: ShowEngine, timeout: TimeInterval = 8) async {
    _ = await waitUntil(2) { engine.progress.isRunning }
    _ = await waitUntil(timeout) { !engine.progress.isRunning }
}

// MARK: - 卡片 JSON 解析（与服务端 / 网页端互通）

final class CardActionDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> CardAction {
        try JSONDecoder().decode(CardAction.self, from: Data(json.utf8))
    }

    func testRejectsUnknownKind() {
        XCTAssertThrowsError(try decode(#"{"kind":"drop_table"}"#))
    }

    func testAcceptsEveryWhitelistedKind() throws {
        XCTAssertEqual(CardAction.kinds.count, 12)
        for kind in CardAction.kinds {
            XCTAssertNoThrow(try decode(#"{"kind":"\#(kind)"}"#), "kind=\(kind) 应被接受")
        }
    }

    func testTargetsAreDedupedAndSorted() throws {
        let a = try decode(#"{"kind":"mute","chs":[5,2,2,9]}"#)
        XCTAssertEqual(a.chs, [2, 5, 9])
    }

    func testTargetsAreClampedToRange() throws {
        XCTAssertEqual(try decode(#"{"kind":"mute","chs":[0,99]}"#).chs, [1, 32])
        XCTAssertEqual(try decode(#"{"kind":"mute_bus","buses":[3,40]}"#).buses, [3, 16])
    }

    func testLegacySingleValueForm() throws {
        XCTAssertEqual(try decode(#"{"kind":"mute","ch":7}"#).chs, [7])
    }

    func testEmptyTargetListFallsBackToLowerBound() throws {
        XCTAssertEqual(try decode(#"{"kind":"mute","chs":[]}"#).chs, [1])
    }

    func testFadeValuesAreClamped() throws {
        let a = try decode(#"{"kind":"fade_ch","to":5.0,"duration":999.0}"#)
        XCTAssertEqual(a.to, 1, accuracy: 0.0001)
        XCTAssertEqual(a.duration, 30, accuracy: 0.0001)
    }

    func testFadeDurationLowerBound() throws {
        XCTAssertEqual(try decode(#"{"kind":"fade_all","duration":0.01}"#).duration, 0.5, accuracy: 0.0001)
    }

    func testSceneAndWaitAreClamped() throws {
        XCTAssertEqual(try decode(#"{"kind":"scene","scene":-5}"#).scene, 1)
        XCTAssertEqual(try decode(#"{"kind":"scene","scene":500}"#).scene, 99)
        XCTAssertEqual(try decode(#"{"kind":"wait","duration":600.0}"#).duration, 60, accuracy: 0.0001)
    }

    func testUnknownCurveFallsBackToLinear() throws {
        XCTAssertEqual(try decode(#"{"kind":"fade_all","curve":"wobble"}"#).curve, "linear")
        for c in MixerSpec.curves {
            XCTAssertEqual(try decode(#"{"kind":"fade_all","curve":"\#(c)"}"#).curve, c)
        }
    }

    func testAtOffsetParsing() throws {
        XCTAssertEqual(try decode(#"{"kind":"wait","at":2.5}"#).at, 2.5, accuracy: 0.0001)
        XCTAssertLessThan(try decode(#"{"kind":"wait"}"#).at, 0)
        XCTAssertEqual(try decode(#"{"kind":"wait","at":9999.0}"#).at, 600, accuracy: 0.0001)
    }

    func testRelDbGroups() throws {
        let bus = try decode(#"{"kind":"rel_db","group":"bus","buses":[3,20]}"#)
        XCTAssertEqual(bus.group, "bus")
        XCTAssertEqual(bus.buses, [3, 16])

        let ch = try decode(#"{"kind":"rel_db","group":"ch","chs":[1,2]}"#)
        XCTAssertEqual(ch.chs, [1, 2])

        let dca = try decode(#"{"kind":"rel_db","group":"dca","dcas":[2,99]}"#)
        XCTAssertEqual(dca.dcas, [2, 8])

        XCTAssertEqual(try decode(#"{"kind":"rel_db","group":"matrix"}"#).group, "ch")
    }

    func testRelDbDeltaIsClamped() throws {
        XCTAssertEqual(try decode(#"{"kind":"rel_db","delta_db":500.0}"#).deltaDb, 30, accuracy: 0.0001)
        XCTAssertEqual(try decode(#"{"kind":"rel_db","delta_db":-500.0}"#).deltaDb, -30, accuracy: 0.0001)
    }

    /// 直接吃服务端 `user_config.json` 里的卡片结构
    func testDecodesServerSideCardJSON() throws {
        let json = """
        {"id":"dinner","name":"晚宴","desc":"x","pinned":false,
         "actions":[{"kind":"mute","chs":[1,2]},
                    {"kind":"fade_ch","chs":[15],"to":0.3,"duration":10,"curve":"linear"},
                    {"kind":"rel_db","group":"ch","chs":[1],"delta_db":3,"duration":2,"at":1.5}]}
        """
        let card = try JSONDecoder().decode(TimelineCard.self, from: Data(json.utf8))
        XCTAssertEqual(card.id, "dinner")
        XCTAssertEqual(card.actions.count, 3)
        XCTAssertEqual(card.actions[2].kind, "rel_db")
        XCTAssertEqual(card.actions[2].at, 1.5, accuracy: 0.0001)
        XCTAssertEqual(card.actions[2].group, "ch")
        XCTAssertNil(card.next)
    }

    func testEncodeKeepsOnlyRelevantFields() throws {
        let action = CardAction(kind: "fade_ch", chs: [3], to: 0.6, duration: 2, curve: "smooth")
        let data = try JSONEncoder().encode(action)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["kind"] as? String, "fade_ch")
        XCTAssertEqual(try XCTUnwrap(obj["to"] as? Double), 0.6, accuracy: 0.0001)
        XCTAssertEqual(obj["curve"] as? String, "smooth")
        XCTAssertEqual(try XCTUnwrap(obj["duration"] as? Double), 2, accuracy: 0.0001)
        // 与 kind 无关的字段不应出现
        XCTAssertNil(obj["scene"])
        XCTAssertNil(obj["delta_db"])
        XCTAssertNil(obj["at"])
    }

    func testCardLibraryRoundTrip() throws {
        let cards = TimelineCard.defaults()
        let data = try JSONEncoder().encode(cards)
        let back = try JSONDecoder().decode([TimelineCard].self, from: data)

        XCTAssertEqual(cards.count, back.count)
        for (a, b) in zip(cards, back) {
            XCTAssertEqual(a.id, b.id)
            XCTAssertEqual(a.name, b.name)
            XCTAssertEqual(a.actions.count, b.actions.count)
            for (x, y) in zip(a.actions, b.actions) {
                XCTAssertEqual(x.kind, y.kind)
                XCTAssertEqual(x.at, y.at, accuracy: 0.0001)
                XCTAssertEqual(x.duration, y.duration, accuracy: 0.0001)
                XCTAssertEqual(x.chs, y.chs)
                XCTAssertEqual(x.buses, y.buses)
                XCTAssertEqual(x.group, y.group)
            }
        }
    }

    func testFactoryCardsCoverBothEnds() {
        let ids = TimelineCard.defaults().map { $0.id }
        for expected in ["dinner", "speech", "leave", "sync_down", "odd_even"] {
            XCTAssertTrue(ids.contains(expected), "缺少出厂卡片 \(expected)")
        }
        // 出厂卡片里就应含并行与链式示例
        let parallel = TimelineCard.defaults().first { $0.id == "parallel_demo" }
        XCTAssertNotNil(parallel)
        XCTAssertTrue(parallel?.hasParallelActions ?? false)
        XCTAssertEqual(parallel?.next, "rel_db_demo")
    }
}

// MARK: - 时间轴排布

final class ShowTimelineTests: XCTestCase {

    func testSequentialLayout() {
        let mixer = MockMixer()
        let engine = makeEngine(mixer)
        let card = TimelineCard(id: "t", name: "t", actions: [
            CardAction(kind: "wait", duration: 1),
            CardAction(kind: "fade_ch", chs: [1], to: 0.5, duration: 2),
        ])
        let tl = engine.buildTimeline(card)
        XCTAssertEqual(tl.count, 2)
        XCTAssertEqual(tl[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(tl[0].duration, 1, accuracy: 0.001)
        XCTAssertEqual(tl[1].start, 1, accuracy: 0.001)
        XCTAssertEqual(tl[1].duration, 2, accuracy: 0.001)
    }

    /// 服务端语义：cursor 恒等于"该动作的结束时刻"，
    /// 因此带 at 的动作也会把后续顺序动作顺延到它之后。
    func testAtOffsetPushesFollowingSequentialActions() {
        let mixer = MockMixer()
        let engine = makeEngine(mixer)
        let card = TimelineCard(id: "t", name: "t", actions: [
            CardAction(kind: "fade_ch", chs: [1], to: 0.5, duration: 3),
            CardAction(kind: "fade_ch", chs: [2], to: 0.5, duration: 2, at: 10),
            CardAction(kind: "fade_ch", chs: [3], to: 0.5, duration: 1),
        ])
        let tl = engine.buildTimeline(card)
        XCTAssertEqual(tl[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(tl[1].start, 10, accuracy: 0.001)
        XCTAssertFalse(tl[0].isParallel)
        XCTAssertTrue(tl[1].isParallel)
        XCTAssertEqual(tl[2].start, 12, accuracy: 0.001)
    }

    func testCardTotalSeconds() {
        let card = TimelineCard(id: "t", name: "t", actions: [
            CardAction(kind: "fade_all", to: 0, duration: 3),
            CardAction(kind: "wait", duration: 2, at: 1),
        ])
        // 第二条 at=1、dur=2 → end=3；cursor 推到 3；总时长 3
        XCTAssertEqual(card.totalSeconds, 3, accuracy: 0.001)
    }

    func testInstantActionsOccupyZero() {
        XCTAssertEqual(CardAction(kind: "mute", chs: [1]).occupiesSeconds, 0)
        XCTAssertEqual(CardAction(kind: "scene", scene: 3).occupiesSeconds, 0)
        XCTAssertEqual(CardAction(kind: "unmute_all").occupiesSeconds, 0)
        XCTAssertEqual(CardAction(kind: "fade_ch", chs: [1], duration: 2).occupiesSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(CardAction(kind: "wait", duration: 4).occupiesSeconds, 4, accuracy: 0.001)
    }

    func testFadeAllTargetsEveryGroup() {
        let mixer = MockMixer()
        let engine = makeEngine(mixer)
        let targets = engine.fadeTargets(for: CardAction(kind: "fade_all", to: 0, duration: 1))
        // 32 ch + 16 bus + 8 dca + 6 auxin + 2 usb + 8 fxret + 6 mtx + 1 main
        XCTAssertEqual(targets.count, 79)
    }

    func testOddEvenSplitsChannels() {
        let mixer = MockMixer()
        let engine = makeEngine(mixer)
        let targets = engine.fadeTargets(for:
            CardAction(kind: "fade_odd_even", oddTo: 0.9, evenTo: 0.1, duration: 1))
        XCTAssertEqual(targets.count, 32)
        XCTAssertEqual(targets[0].to, 0.9, accuracy: 0.001)   // ch1 奇
        XCTAssertEqual(targets[1].to, 0.1, accuracy: 0.001)   // ch2 偶
    }

    func testNonFadeActionsHaveNoTargets() {
        let mixer = MockMixer()
        let engine = makeEngine(mixer)
        for kind in ["mute", "mute_bus", "scene", "unmute_all", "wait"] {
            XCTAssertTrue(engine.fadeTargets(for: CardAction(kind: kind)).isEmpty, kind)
        }
    }
}

// MARK: - 执行

final class ShowExecutionTests: XCTestCase {

    func testFadeReachesTargetValue() async {
        let mixer = MockMixer()
        mixer.setInitialFader(kind: "ch_fader", idx: 1, to: 0)
        let card = TimelineCard(id: "c", name: "c", actions: [
            CardAction(kind: "fade_ch", chs: [1], to: 1, duration: 0.5)
        ])
        let engine = makeEngine(mixer, [card])
        engine.run(cardId: "c")
        await waitIdle(engine)

        XCTAssertEqual(mixer.readFader(kind: "ch_fader", idx: 1), 1, accuracy: 0.02)
        XCTAssertTrue(mixer.writes.allSatisfy { $0.source == .action })
    }

    func testFadeFromStartsAtSpecifiedValue() async {
        let mixer = MockMixer()
        mixer.setInitialFader(kind: "ch_fader", idx: 5, to: 0.9)   // 起点应被 frm 覆盖
        let card = TimelineCard(id: "c", name: "c", actions: [
            CardAction(kind: "fade_from", to: 0.6, frm: 0.2, duration: 0.5, singleCh: 5)
        ])
        let engine = makeEngine(mixer, [card])

        // 首次写入应是把推子置到 frm
        engine.run(cardId: "c")
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(mixer.writes.first?.value ?? -1, 0.2, accuracy: 0.001)

        await waitIdle(engine)
        XCTAssertEqual(mixer.readFader(kind: "ch_fader", idx: 5), 0.6, accuracy: 0.03)
    }

    func testMuteWritesZeroAndSceneIsRaw() async {
        let mixer = MockMixer()
        let card = TimelineCard(id: "c", name: "c", actions: [
            CardAction(kind: "mute", chs: [3, 4]),
            CardAction(kind: "scene", scene: 7),
        ])
        let engine = makeEngine(mixer, [card])
        engine.run(cardId: "c")
        await waitIdle(engine)

        let ons = mixer.writes.filter { $0.kind == "ch_on" }
        XCTAssertEqual(ons.count, 2)
        XCTAssertTrue(ons.allSatisfy { $0.value == 0 })
        XCTAssertEqual(ons.map { $0.idx }, [3, 4])
        XCTAssertEqual(mixer.rawAddresses, ["/scene/7/load"])
    }

    func testUnmuteAllTouchesChannelsAndBuses() async {
        let mixer = MockMixer()
        let card = TimelineCard(id: "c", name: "c", actions: [CardAction(kind: "unmute_all")])
        let engine = makeEngine(mixer, [card])
        engine.run(cardId: "c")
        await waitIdle(engine)

        XCTAssertEqual(mixer.writes.filter { $0.kind == "ch_on" }.count, 32)
        XCTAssertEqual(mixer.writes.filter { $0.kind == "bus_on" }.count, 16)
    }

    /// rel_db 按 dB 差量换算：0 dB 位置整体 +3 dB
    func testRelDbConvertsThroughDb() async {
        let mixer = MockMixer()
        mixer.setInitialFader(kind: "ch_fader", idx: 1, to: 0.75)   // 0 dB
        let card = TimelineCard(id: "c", name: "c", actions: [
            CardAction(kind: "rel_db", chs: [1], duration: 0.5, deltaDb: 3, group: "ch")
        ])
        let engine = makeEngine(mixer, [card])
        engine.run(cardId: "c")
        await waitIdle(engine)

        // 0 dB + 3 dB → dbToFader(3) = 0.75 + 3/10*0.25 = 0.825
        XCTAssertEqual(mixer.readFader(kind: "ch_fader", idx: 1), 0.825, accuracy: 0.02)
    }

    func testRelDbIsClampedAtTop() async {
        let mixer = MockMixer()
        mixer.setInitialFader(kind: "ch_fader", idx: 1, to: 0.95)   // +8 dB
        let card = TimelineCard(id: "c", name: "c", actions: [
            CardAction(kind: "rel_db", chs: [1], duration: 0.5, deltaDb: 30, group: "ch")
        ])
        let engine = makeEngine(mixer, [card])
        engine.run(cardId: "c")
        await waitIdle(engine)

        XCTAssertLessThanOrEqual(mixer.readFader(kind: "ch_fader", idx: 1), 1.0001)
    }

    // MARK: 卡片链

    func testNextChainRunsSecondCard() async {
        let mixer = MockMixer()
        let a = TimelineCard(id: "a", name: "A",
                             actions: [CardAction(kind: "mute", chs: [1])], next: "b")
        let b = TimelineCard(id: "b", name: "B",
                             actions: [CardAction(kind: "mute", chs: [2])])
        let engine = makeEngine(mixer, [a, b])

        engine.run(cardId: "a")
        let ok = await waitUntil(8) { mixer.writes.filter { $0.kind == "ch_on" }.count >= 2 }
        XCTAssertTrue(ok, "卡片链应自动接续第二张")
        _ = await waitUntil(3) { !engine.progress.isRunning }

        let ons = mixer.writes.filter { $0.kind == "ch_on" }
        XCTAssertEqual(ons.count, 2)
        XCTAssertEqual(ons.map { $0.idx }.sorted(), [1, 2])
    }

    func testChainLoopIsDetected() async {
        let mixer = MockMixer()
        let warnings = Collector()
        let a = TimelineCard(id: "a", name: "A",
                             actions: [CardAction(kind: "mute", chs: [1])], next: "b")
        let b = TimelineCard(id: "b", name: "B",
                             actions: [CardAction(kind: "mute", chs: [2])], next: "a")
        let engine = makeEngine(mixer, [a, b])
        engine.eventSink = { warnings.append($0) }

        engine.run(cardId: "a")
        _ = await waitUntil(6) { mixer.writes.filter { $0.kind == "ch_on" }.count >= 2 }
        // 环被拦下后不应继续执行
        try? await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(mixer.writes.filter { $0.kind == "ch_on" }.count, 2)
        XCTAssertTrue(warnings.all.contains { $0.contains("循环") }, "应报告卡片链循环")
    }

    func testStopFreezesFadeWithoutWritingFinalValue() async {
        let mixer = MockMixer()
        mixer.setInitialFader(kind: "ch_fader", idx: 1, to: 0)
        let card = TimelineCard(id: "c", name: "c", actions: [
            CardAction(kind: "fade_ch", chs: [1], to: 1, duration: 3)
        ])
        let engine = makeEngine(mixer, [card])
        engine.run(cardId: "c")
        try? await Task.sleep(nanoseconds: 400_000_000)
        engine.stopAll()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let v = mixer.readFader(kind: "ch_fader", idx: 1)
        XCTAssertGreaterThan(v, 0)          // 已经动过
        XCTAssertLessThan(v, 0.6)           // 但没跑完、也没写终值
        XCTAssertFalse(engine.progress.isRunning)
    }
}

// MARK: - 冲突策略

final class ShowConflictTests: XCTestCase {

    func testConflictCheckIsInertWithoutRunningCard() {
        let mixer = MockMixer()
        let engine = makeEngine(mixer)
        XCTAssertNil(engine.checkManualTakeover(kind: "ch_fader", idx: 1))
        XCTAssertFalse(engine.isDriven(kind: "ch_fader", idx: 1))
    }

    /// 手动干预只冻结被碰的那一路，另一路继续跑到终值
    func testManualTakeoverFreezesOnlyTargetedChannel() async {
        let mixer = MockMixer()
        mixer.setInitialFader(kind: "ch_fader", idx: 1, to: 0)
        mixer.setInitialFader(kind: "ch_fader", idx: 2, to: 0)
        let card = TimelineCard(id: "c", name: "双通道渐变", actions: [
            CardAction(kind: "fade_ch", chs: [1, 2], to: 1, duration: 1.5)
        ])
        let engine = makeEngine(mixer, [card])

        let warnings = Collector()
        engine.eventSink = { warnings.append($0) }

        engine.run(cardId: "c")
        // 等该路先被登记为"驱动中"再动手抢
        _ = await waitUntil(3) { engine.isDriven(kind: "ch_fader", idx: 1) }
        try? await Task.sleep(nanoseconds: 300_000_000)

        // 模拟用户在手机上抢走通道 1
        XCTAssertNotNil(engine.checkManualTakeover(kind: "ch_fader", idx: 1))
        let frozen = mixer.readFader(kind: "ch_fader", idx: 1)

        await waitIdle(engine)

        // 被冻结的那一路停手
        XCTAssertEqual(mixer.readFader(kind: "ch_fader", idx: 1), frozen, accuracy: 0.05)
        XCTAssertLessThan(mixer.readFader(kind: "ch_fader", idx: 1), 0.9)
        // 另一路照常跑完
        XCTAssertEqual(mixer.readFader(kind: "ch_fader", idx: 2), 1, accuracy: 0.03)
        XCTAssertTrue(warnings.all.contains { $0.contains("手动干预") })
    }

    func testTakeoverIsReportedOnlyOncePerChannel() async {
        let mixer = MockMixer()
        let card = TimelineCard(id: "c", name: "c", actions: [
            CardAction(kind: "fade_ch", chs: [1], to: 1, duration: 3)
        ])
        let engine = makeEngine(mixer, [card])
        engine.run(cardId: "c")

        // 卡片刚启动时该路应被登记为"驱动中"
        let driven = await waitUntil(2) { engine.isDriven(kind: "ch_fader", idx: 1) }
        XCTAssertTrue(driven)

        XCTAssertNotNil(engine.checkManualTakeover(kind: "ch_fader", idx: 1))
        XCTAssertNil(engine.checkManualTakeover(kind: "ch_fader", idx: 1), "同一路只告警一次")
        engine.stopAll()
    }
}

// MARK: - 桥接引擎

final class BridgeEngineTests: XCTestCase {

    func testEchoSuppression() {
        let bridge = BridgeEngine()
        bridge.setEnabled(true)
        bridge.noteForward(kind: "ch_fader", idx: 1, value: 0.5)

        XCTAssertEqual(bridge.classify(kind: "ch_fader", idx: 1, value: 0.5), .echo)
        XCTAssertEqual(bridge.classify(kind: "ch_fader", idx: 1, value: 0.51), .echo, "容差内算回声")
        XCTAssertEqual(bridge.classify(kind: "ch_fader", idx: 1, value: 0.9), .remoteChange, "超出容差是外部变化")
        XCTAssertEqual(bridge.classify(kind: "ch_fader", idx: 2, value: 0.5), .remoteChange, "其它通道是外部变化")
    }

    func testEchoWindowExpires() {
        let bridge = BridgeEngine()
        bridge.noteForward(kind: "bus_fader", idx: 2, value: 0.3)
        // 直接构造过期记录：用一个明显不同的值模拟窗口外
        XCTAssertEqual(bridge.classify(kind: "bus_fader", idx: 2, value: 0.3), .echo)
        XCTAssertEqual(BridgeEngine.echoWindow, 2.0, accuracy: 0.0001)
        XCTAssertEqual(BridgeEngine.echoTolerance, 0.02, accuracy: 0.0001)
    }

    func testStateTransitions() {
        let bridge = BridgeEngine()
        XCTAssertEqual(bridge.state, .off)

        bridge.setEnabled(true)
        XCTAssertEqual(bridge.state, .link)

        bridge.noteActivity()
        XCTAssertEqual(bridge.state, .online)

        bridge.setEnabled(false)
        XCTAssertEqual(bridge.state, .off)
        XCTAssertEqual(bridge.classify(kind: "ch_fader", idx: 1, value: 0.5), .remoteChange,
                       "停用后记录被清空")
    }

    func testEventsAreRingBuffered() {
        let bridge = BridgeEngine()
        for i in 1...(BridgeEngine.eventLimit + 5) {
            bridge.pushEvent("事件 \(i)", isWarning: true)
        }
        XCTAssertEqual(bridge.events.count, BridgeEngine.eventLimit)
        XCTAssertEqual(bridge.events.last?.text, "事件 \(BridgeEngine.eventLimit + 5)")

        bridge.clearEvents()
        XCTAssertTrue(bridge.events.isEmpty)
    }

    func testNoActivityIsNotStale() {
        let bridge = BridgeEngine()
        bridge.setEnabled(true)
        bridge.refreshStaleness()
        // 还没收到过任何回包时不应判为 stale（那只是"还没连上"）
        XCTAssertEqual(bridge.state, .link)
    }
}

// MARK: - 台面访问层 / 地址 / 曲线

final class MixerTableTests: XCTestCase {

    func testFaderRoundTripAcrossGroups() {
        var s = RemoteState()
        let samples: [(String, Int)] = [
            ("ch_fader", 1), ("ch_fader", 32), ("bus_fader", 16), ("dca_fader", 8),
            ("auxin_fader", 6), ("usb_fader", 2), ("fxret_fader", 8), ("mtx_fader", 6),
            ("main_fader", 0),
        ]
        for (kind, idx) in samples {
            s.setFader(kind: kind, idx: idx, to: 0.42)
            XCTAssertEqual(s.fader(kind: kind, idx: idx), 0.42, accuracy: 0.001, "\(kind)#\(idx)")
        }
    }

    func testOnRoundTripAcrossGroups() {
        var s = RemoteState()
        for kind in ["ch_on", "bus_on", "dca_on", "auxin_on", "usb_on", "fxret_on", "mtx_on", "main_on"] {
            s.setOn(kind: kind, idx: 1, to: false)
            XCTAssertFalse(s.isOn(kind: kind, idx: 1), kind)
            s.setOn(kind: kind, idx: 1, to: true)
            XCTAssertTrue(s.isOn(kind: kind, idx: 1), kind)
        }
    }

    func testFaderIsClamped() {
        var s = RemoteState()
        s.setFader(kind: "ch_fader", idx: 1, to: 5)
        XCTAssertEqual(s.fader(kind: "ch_fader", idx: 1), 1, accuracy: 0.0001)
        s.setFader(kind: "ch_fader", idx: 1, to: -3)
        XCTAssertEqual(s.fader(kind: "ch_fader", idx: 1), 0, accuracy: 0.0001)
    }

    func testDcaMaskAndMembers() {
        var s = RemoteState()
        s.setDcaMask(ofChannel: 5, to: 0b0000_0011)   // DCA1 + DCA2
        XCTAssertEqual(s.dcaMask(ofChannel: 5), 3)
        XCTAssertEqual(s.dcaMembers(1), [5])
        XCTAssertEqual(s.dcaMembers(2), [5])
        XCTAssertEqual(s.dcaMembers(3), [])

        s.setDcaMask(ofChannel: 5, to: 0)
        XCTAssertEqual(s.dcaMembers(1), [])
    }

    func testDisplayNameFallbacks() {
        var s = RemoteState()
        XCTAssertEqual(s.displayName(kind: "ch_fader", idx: 3), "通道 03")
        s.setFader(kind: "ch_fader", idx: 3, to: 0.5)
        XCTAssertEqual(s.displayName(kind: "ch_fader", idx: 3), "通道 03")
        // 真台原名
        var ch = s.channels["ch/03"] ?? ChannelState()
        ch.x32Name = "军鼓"
        s.channels["ch/03"] = ch
        XCTAssertEqual(s.displayName(kind: "ch_fader", idx: 3), "军鼓")
        XCTAssertEqual(s.targetLabel(kind: "ch_fader", idx: 3), "军鼓(通道03)")
    }

    func testAddressParsingRoundTrip() {
        let samples: [(String, Int)] = [
            ("ch_fader", 1), ("ch_on", 32), ("bus_fader", 16), ("bus_on", 1),
            ("dca_fader", 3), ("dca_on", 8), ("auxin_fader", 6), ("usb_on", 2),
            ("fxret_fader", 8), ("mtx_on", 6), ("main_fader", 0), ("main_on", 0),
            ("ch_dca", 12),
        ]
        for (kind, idx) in samples {
            let address = MixerSpec.address(kind: kind, idx: idx)
            XCTAssertNotNil(address, "\(kind) 应有地址")
            let parsed = OscAddressParser.parse(address ?? "")
            XCTAssertEqual(parsed?.kind, kind, address ?? "")
            XCTAssertEqual(parsed?.idx, idx, address ?? "")
        }
    }

    func testDcaAddressIsZeroPadded() {
        XCTAssertEqual(MixerSpec.dcaFader(1), "/dca/01/fader")
        XCTAssertEqual(MixerSpec.dcaOn(8), "/dca/08/on")
        XCTAssertEqual(MixerSpec.channelDcaMask(1), "/ch/01/mix/dca")
        XCTAssertEqual(MixerSpec.faderAddress(kind: "main_fader", idx: 0), "/main/st/mix/fader")
        XCTAssertEqual(MixerSpec.sceneLoad(2), "/scene/2/load")
    }

    func testRealDeskGrpDcaFormIsAccepted() {
        // 真机固件也有 /ch/NN/grp/dca 写法，解析端必须兼容
        let parsed = OscAddressParser.parse("/ch/07/grp/dca")
        XCTAssertEqual(parsed?.kind, "ch_dca")
        XCTAssertEqual(parsed?.idx, 7)
    }

    func testNonTargetAddressesReturnNil() {
        for addr in ["/xinfo", "/scene/3/load", "/ch/01/config/name", "/meters/1", "/xremote"] {
            XCTAssertNil(OscAddressParser.parse(addr), addr)
        }
    }

    func testNamedAddresses() {
        XCTAssertEqual(MixerSpec.nameAddress(group: "ch", idx: 4), "/ch/04/config/name")
        XCTAssertEqual(MixerSpec.nameAddress(group: "main", idx: 0), "/main/st/config/name")
        XCTAssertNil(MixerSpec.nameAddress(group: "nope", idx: 1))
    }

    func testKindGroup() {
        XCTAssertEqual(MixerSpec.kindGroup("ch_fader"), "ch")
        XCTAssertEqual(MixerSpec.kindGroup("main_on"), "main")
        XCTAssertEqual(MixerSpec.kindGroup("ch_dca"), "ch")
        XCTAssertEqual(MixerSpec.count(of: "ch"), 32)
        XCTAssertEqual(MixerSpec.count(of: "bus"), 16)
        XCTAssertEqual(MixerSpec.count(of: "dca"), 8)
    }
}

final class MixerCurveTests: XCTestCase {

    func testDbRoundTrip() {
        for db in [-90, -80, -70, -60, -57.5, -50, -30, -10, -3, 0, 3, 6, 10] as [Float] {
            let f = MixerSpec.dbToFader(db)
            XCTAssertEqual(MixerSpec.faderToDb(f), db, accuracy: 0.01, "\(db) dB 往返失真")
        }
    }

    func testKeyScales() {
        XCTAssertEqual(MixerSpec.faderToDb(0.75), 0, accuracy: 0.001)
        XCTAssertEqual(MixerSpec.faderToDb(1.0), 10, accuracy: 0.001)
        XCTAssertEqual(MixerSpec.faderToDb(0), -90, accuracy: 0.001)
        XCTAssertEqual(MixerSpec.dbToFader(0), 0.75, accuracy: 0.001)
        XCTAssertEqual(MixerSpec.dbToFader(10), 1, accuracy: 0.001)
        XCTAssertEqual(MixerSpec.dbToFader(-90), 0, accuracy: 0.001)
    }

    func testFaderToDbIsMonotonic() {
        var last: Float = -1000
        for i in 0...200 {
            let f = Float(i) / 200
            let db = MixerSpec.faderToDb(f)
            XCTAssertGreaterThanOrEqual(db, last, "f=\(f) 处不单调")
            last = db
        }
    }

    func testCurves() {
        XCTAssertEqual(MixerSpec.applyCurve(0.5, "linear"), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MixerSpec.applyCurve(0.5, "ease_in"), 0.25, accuracy: 0.0001)
        XCTAssertEqual(MixerSpec.applyCurve(0.5, "ease_out"), 0.75, accuracy: 0.0001)
        XCTAssertEqual(MixerSpec.applyCurve(0.5, "smooth"), 0.5, accuracy: 0.0001)
        // 各曲线端点固定
        for c in MixerSpec.curves {
            XCTAssertEqual(MixerSpec.applyCurve(0, c), 0, accuracy: 0.0001, c)
            XCTAssertEqual(MixerSpec.applyCurve(1, c), 1, accuracy: 0.0001, c)
        }
        XCTAssertEqual(MixerSpec.applyCurve(0.5, "未知"), 0.5, accuracy: 0.0001)
    }
}
