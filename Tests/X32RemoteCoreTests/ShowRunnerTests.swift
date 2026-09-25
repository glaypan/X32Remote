import XCTest
@testable import X32RemoteCore

// MARK: - Mock Implementations

/// Mock OSC 消息发送器，记录所有发出的消息
final class MockOscSender: OscSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentMessages: [(address: String, args: [OscArgument])] = []

    var sentMessages: [(address: String, args: [OscArgument])] {
        lock.withLock { _sentMessages }
    }

    var sentAddresses: [String] {
        sentMessages.map(\.address)
    }

    func send(address: String, args: [OscArgument]) async throws {
        lock.withLock {
            _sentMessages.append((address: address, args: args))
        }
    }

    func reset() {
        lock.withLock { _sentMessages.removeAll() }
    }
}

/// Mock 状态提供器，提供可控的通道/DCA 状态
final class MockStateProvider: StateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _channelFaders: [String: Float] = [:]
    private var _dcaFaders: [Int: Float] = [:]

    func channelFader(for key: ChannelKey) -> Float {
        lock.withLock { _channelFaders[key.rawValue] ?? 0.0 }
    }

    func dcaFader(for group: Int) -> Float {
        lock.withLock { _dcaFaders[group] ?? 0.0 }
    }

    func setChannelFader(_ value: Float, for key: ChannelKey) {
        lock.withLock { _channelFaders[key.rawValue] = value }
    }

    func setDcaFader(_ value: Float, for group: Int) {
        lock.withLock { _dcaFaders[group] = value }
    }
}

// MARK: - ShowRunnerTests

final class ShowRunnerTests: XCTestCase {

    var sender: MockOscSender!
    var state: MockStateProvider!
    var runner: ShowRunner!

    override func setUp() {
        super.setUp()
        sender = MockOscSender()
        state  = MockStateProvider()
        runner = ShowRunner(sender: sender, stateProvider: state)
    }

    override func tearDown() {
        runner = nil
        state  = nil
        sender = nil
        super.tearDown()
    }

    // MARK: - sceneRecall

    func testSceneRecall_sendsCorrectOscMessage() async throws {
        let action = ShowAction.sceneRecall(scene: 5)
        let card = ShowCard(name: "Scene 5", actions: [action])

        try await runner.execute(card: card)

        XCTAssertEqual(sender.sentAddresses, ["/scene/5/load"])
        XCTAssertEqual(sender.sentMessages.first?.args.count, 0)
    }

    func testSceneRecall_variousSceneNumbers() async throws {
        for scene in [1, 10, 50, 100] {
            sender.reset()
            let card = ShowCard(name: "Scene \(scene)", actions: [.sceneRecall(scene: scene)])
            try await runner.execute(card: card)
            XCTAssertEqual(sender.sentAddresses, ["/scene/\(scene)/load"], "Scene \(scene) failed")
        }
    }

    // MARK: - dcaFader

    func testDcaFader_sendsCorrectAddress() async throws {
        let action = ShowAction.dcaFader(group: 3, value: 0.75)
        let card = ShowCard(name: "DCA 3 Unity", actions: [action])

        try await runner.execute(card: card)

        XCTAssertEqual(sender.sentAddresses, ["/dca/03/fader"])
        if case .float(let v) = sender.sentMessages.first?.args.first {
            XCTAssertEqual(v, 0.75, accuracy: 0.0001)
        } else {
            XCTFail("Expected float argument")
        }
    }

    func testDcaFader_allGroups() async throws {
        for group in 1...8 {
            sender.reset()
            let card = ShowCard(name: "DCA \(group)", actions: [.dcaFader(group: group, value: 0.5)])
            try await runner.execute(card: card)
            XCTAssertEqual(sender.sentAddresses, [String(format: "/dca/%02d/fader", group)])
        }
    }

    // MARK: - dcaMute

    func testDcaMute_mute_sendsZeroOnValue() async throws {
        let action = ShowAction.dcaMute(group: 1, muted: true)
        let card = ShowCard(name: "DCA 1 Mute", actions: [action])

        try await runner.execute(card: card)

        XCTAssertEqual(sender.sentAddresses, ["/dca/01/on"])
        if case .int(let v) = sender.sentMessages.first?.args.first {
            // X32: on=1 表示未静音，on=0 表示静音
            XCTAssertEqual(v, 0)
        } else {
            XCTFail("Expected int argument")
        }
    }

    func testDcaMute_unmute_sendsOneOnValue() async throws {
        let action = ShowAction.dcaMute(group: 2, muted: false)
        let card = ShowCard(name: "DCA 2 Unmute", actions: [action])

        try await runner.execute(card: card)

        XCTAssertEqual(sender.sentAddresses, ["/dca/02/on"])
        if case .int(let v) = sender.sentMessages.first?.args.first {
            XCTAssertEqual(v, 1)
        } else {
            XCTFail("Expected int argument")
        }
    }

    // MARK: - channelFader

    func testChannelFader_sendsCorrectAddress() async throws {
        let key = ChannelKey.channel(1)
        let action = ShowAction.channelFader(channel: key, value: 0.75)
        let card = ShowCard(name: "Ch 1 Unity", actions: [action])

        try await runner.execute(card: card)

        XCTAssertEqual(sender.sentAddresses, ["/ch/01/mix/fader"])
    }

    func testChannelFader_paddingFor_ch01_to_ch09() async throws {
        for ch in 1...9 {
            sender.reset()
            let key = ChannelKey.channel(ch)
            let card = ShowCard(name: "Ch \(ch)", actions: [.channelFader(channel: key, value: 0.5)])
            try await runner.execute(card: card)
            let expected = "/ch/\(String(format: "%02d", ch))/mix/fader"
            XCTAssertEqual(sender.sentAddresses, [expected], "Channel \(ch) failed")
        }
    }

    func testChannelFader_ch32_correctAddress() async throws {
        let key = ChannelKey.channel(32)
        let card = ShowCard(name: "Ch 32", actions: [.channelFader(channel: key, value: 0.0)])
        try await runner.execute(card: card)
        XCTAssertEqual(sender.sentAddresses, ["/ch/32/mix/fader"])
    }

    // MARK: - channelMute

    func testChannelMute_muted_sendsZero() async throws {
        let key = ChannelKey.channel(5)
        let action = ShowAction.channelMute(channel: key, muted: true)
        let card = ShowCard(name: "Ch 5 Mute", actions: [action])

        try await runner.execute(card: card)

        XCTAssertEqual(sender.sentAddresses, ["/ch/05/mix/on"])
        if case .int(let v) = sender.sentMessages.first?.args.first {
            XCTAssertEqual(v, 0)
        } else {
            XCTFail("Expected int argument")
        }
    }

    // MARK: - channelGain

    func testChannelGain_sendsCorrectAddress() async throws {
        let key = ChannelKey.channel(1)
        let action = ShowAction.channelGain(channel: key, gainDb: 12.0)
        let card = ShowCard(name: "Ch 1 Gain", actions: [action])

        try await runner.execute(card: card)

        XCTAssertEqual(sender.sentAddresses, ["/ch/01/preamp/gain"])
    }

    func testChannelGain_valueIsNormalized() async throws {
        // X32 gain range: -12 to +60 dB，normalized to 0.0–1.0
        let key = ChannelKey.channel(1)
        let action = ShowAction.channelGain(channel: key, gainDb: 24.0)
        let card = ShowCard(name: "Ch 1 Gain 24dB", actions: [action])

        try await runner.execute(card: card)

        if case .float(let v) = sender.sentMessages.first?.args.first {
            XCTAssertGreaterThanOrEqual(v, 0.0)
            XCTAssertLessThanOrEqual(v, 1.0)
        } else {
            XCTFail("Expected float argument")
        }
    }

    // MARK: - busSend

    func testBusSend_sendsCorrectAddress() async throws {
        let key = ChannelKey.channel(1)
        let action = ShowAction.busSend(channel: key, bus: 3, value: 0.5)
        let card = ShowCard(name: "Ch 1 Bus 3", actions: [action])

        try await runner.execute(card: card)

        XCTAssertEqual(sender.sentAddresses, ["/ch/01/mix/03/level"])
    }

    // MARK: - delay

    func testDelay_doesNotSendOscMessage() async throws {
        let action = ShowAction.delay(seconds: 0.01) // 10ms 快速延迟用于测试
        let card = ShowCard(name: "Short Delay", actions: [action])

        try await runner.execute(card: card)

        XCTAssertTrue(sender.sentMessages.isEmpty, "Delay should not send OSC messages")
    }

    func testDelay_sequencePreservesOrder() async throws {
        let actions: [ShowAction] = [
            .sceneRecall(scene: 1),
            .delay(seconds: 0.01),
            .dcaFader(group: 1, value: 0.75),
        ]
        let card = ShowCard(name: "Sequence", actions: actions)

        try await runner.execute(card: card)

        XCTAssertEqual(sender.sentAddresses, ["/scene/1/load", "/dca/01/fader"])
    }

    // MARK: - Multiple Actions

    func testMultipleActions_executedInOrder() async throws {
        let actions: [ShowAction] = [
            .sceneRecall(scene: 3),
            .dcaMute(group: 1, muted: true),
            .channelFader(channel: .channel(2), value: 0.5),
        ]
        let card = ShowCard(name: "Complex Card", actions: actions)

        try await runner.execute(card: card)

        XCTAssertEqual(sender.sentAddresses, [
            "/scene/3/load",
            "/dca/01/on",
            "/ch/02/mix/fader",
        ])
    }

    // MARK: - Fade

    func testFade_channelFader_sendsMultipleMessages() async throws {
        let key = ChannelKey.channel(1)
        let fade = ShowFade(
            action: .channelFader(channel: key, value: 0.75),
            fromValue: 0.0,
            durationSeconds: 0.05, // 50ms 快速淡变
            steps: 5
        )
        let card = ShowCard(name: "Fade Test", actions: [], fades: [fade])

        try await runner.execute(card: card)

        // 5 步淡变应发送 5 条消息
        XCTAssertEqual(sender.sentMessages.count, 5)
        XCTAssertTrue(sender.sentAddresses.allSatisfy { $0 == "/ch/01/mix/fader" })
    }

    func testFade_valuesProgressFromStartToEnd() async throws {
        let key = ChannelKey.channel(1)
        let fade = ShowFade(
            action: .channelFader(channel: key, value: 1.0),
            fromValue: 0.0,
            durationSeconds: 0.05,
            steps: 5
        )
        let card = ShowCard(name: "Fade Values", actions: [], fades: [fade])

        try await runner.execute(card: card)

        let values = sender.sentMessages.compactMap { msg -> Float? in
            if case .float(let v) = msg.args.first { return v }
            return nil
        }

        XCTAssertEqual(values.count, 5)
        // 首个值应接近起始值，末值应等于目标值
        XCTAssertLessThan(values.first!, 0.5)
        XCTAssertEqual(values.last!, 1.0, accuracy: 0.001)
    }

    // MARK: - Progress Callback

    func testProgressCallback_calledForEachAction() async throws {
        let actions: [ShowAction] = [
            .sceneRecall(scene: 1),
            .dcaMute(group: 1, muted: false),
            .channelFader(channel: .channel(1), value: 0.75),
        ]
        let card = ShowCard(name: "Progress Test", actions: actions)

        var progressUpdates: [Double] = []
        runner.onProgress = { progress in
            progressUpdates.append(progress)
        }

        try await runner.execute(card: card)

        XCTAssertEqual(progressUpdates.count, 3)
        XCTAssertEqual(progressUpdates.last!, 1.0, accuracy: 0.001)
    }

    func testProgressCallback_monotonicIncreasing() async throws {
        let actions = (1...5).map { ShowAction.sceneRecall(scene: $0) }
        let card = ShowCard(name: "Monotonic Progress", actions: actions)

        var progressUpdates: [Double] = []
        runner.onProgress = { progressUpdates.append($0) }

        try await runner.execute(card: card)

        for i in 1..<progressUpdates.count {
            XCTAssertGreaterThan(progressUpdates[i], progressUpdates[i - 1])
        }
    }

    // MARK: - Cancellation

    func testCancellation_stopsExecution() async throws {
        // 构造一个包含 delay 的长序列，在执行过程中取消
        let actions: [ShowAction] = [
            .sceneRecall(scene: 1),
            .delay(seconds: 5.0), // 长延迟——应被取消
            .sceneRecall(scene: 2),
        ]
        let card = ShowCard(name: "Cancel Test", actions: actions)

        let task = Task {
            try await self.runner.execute(card: card)
        }

        // 给第一个动作执行时间后取消
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        task.cancel()

        // 等待任务完成（已取消）
        let result = await task.result
        switch result {
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        case .success:
            // 取消可能在 delay 前完成也可能不完成，取决于调度时机
            // 允许成功（若取消发生在任务完成后）
            break
        }

        // 不应执行第二个 sceneRecall
        XCTAssertFalse(sender.sentAddresses.contains("/scene/2/load"))
    }

    // MARK: - Error Handling

    func testEmptyCard_executesWithoutError() async throws {
        let card = ShowCard(name: "Empty", actions: [])
        // 不应抛出
        try await runner.execute(card: card)
        XCTAssertTrue(sender.sentMessages.isEmpty)
    }

    func testShowCard_hasCorrectMetadata() {
        let card = ShowCard(
            name: "Main Show",
            actions: [.sceneRecall(scene: 1)],
            notes: "Opening scene"
        )
        XCTAssertEqual(card.name, "Main Show")
        XCTAssertEqual(card.notes, "Opening scene")
        XCTAssertEqual(card.actions.count, 1)
    }

    func testShowCard_idIsUnique() {
        let card1 = ShowCard(name: "Card A", actions: [])
        let card2 = ShowCard(name: "Card B", actions: [])
        XCTAssertNotEqual(card1.id, card2.id)
    }

    // MARK: - ShowCard.defaultShows()

    func testDefaultShows_hasThreeShows() {
        let shows = ShowCard.defaultShows()
        XCTAssertEqual(shows.count, 4)
    }

    func testDefaultShows_dinnerMode_fadesChannel15() {
        let shows = ShowCard.defaultShows()
        let dinner = shows.first { $0.name == "晚宴模式" }
        XCTAssertNotNil(dinner)
        XCTAssertEqual(dinner?.actions.count, 2)
        XCTAssertEqual(dinner?.fades.count, 1)
        let fade = dinner?.fades.first
        XCTAssertEqual(fade?.fromValue ?? -1, 0.75, accuracy: 0.001)
        XCTAssertEqual(fade?.durationSeconds ?? -1, 10.0, accuracy: 0.001)
        if case .channelFader(let key, let value, _, _) = fade?.action.kind {
            XCTAssertEqual(key, ChannelKey.channel(15).rawValue)
            XCTAssertEqual(value, 0.30, accuracy: 0.001)
        } else {
            XCTFail("晚宴模式渐变应为通道推子")
        }
    }

    func testDefaultShows_firstShow_hasAllDcaMuteActions() {
        let shows = ShowCard.defaultShows()
        let first = shows[0]
        XCTAssertEqual(first.name, "All Outputs")
        XCTAssertEqual(first.notes, "Reset all DCA groups from scene 1")

        let dcaMuteActions = first.actions.filter {
            if case .dcaMute = $0.kind { return true }
            return false
        }
        XCTAssertEqual(dcaMuteActions.count, 8)
        XCTAssertTrue(first.actions.contains(where: {
            if case .sceneRecall(1, _) = $0.kind { return true }
            return false
        }))
    }

    func testDefaultShows_secondShow_isDrumsScene() {
        let shows = ShowCard.defaultShows()
        let second = shows[1]
        XCTAssertEqual(second.name, "Drums & Percussion")
        XCTAssertEqual(second.notes, "Recall drums scene")
        XCTAssertEqual(second.actions.count, 1)
        if case .sceneRecall(let scene, _) = second.actions[0].kind {
            XCTAssertEqual(scene, 2)
        } else {
            XCTFail("Expected sceneRecall action")
        }
    }

    func testDefaultShows_thirdShow_isVocalsScene() {
        let shows = ShowCard.defaultShows()
        let third = shows[2]
        XCTAssertEqual(third.name, "Vocals Focus")
        XCTAssertEqual(third.notes, "Recall vocals scene")
        if case .sceneRecall(let scene, _) = third.actions[0].kind {
            XCTAssertEqual(scene, 3)
        } else {
            XCTFail("Expected sceneRecall action")
        }
    }

    // MARK: - ShowCard Codable (Persistence)

    func testShowCard_codableRoundtrip() throws {
        let card = ShowCard(
            name: "Test Show",
            actions: [
                .sceneRecall(scene: 5),
                .dcaMute(group: 1, muted: true),
                .channelFader(channel: .channel(1), value: 0.75),
                .dcaFader(group: 2, value: 0.5),
            ],
            notes: "Test description"
        )

        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(ShowCard.self, from: data)

        XCTAssertEqual(decoded.name, card.name)
        XCTAssertEqual(decoded.notes, card.notes)
        XCTAssertEqual(decoded.id, card.id)
        XCTAssertEqual(decoded.actions.count, card.actions.count)
    }

    func testShowCard_codableRoundtrip_withFades() throws {
        let fade = ShowFade(
            action: .channelFader(channel: .channel(1), value: 0.75),
            fromValue: 0.0,
            durationSeconds: 2.0,
            steps: 10
        )
        let card = ShowCard(name: "Fade Show", actions: [.sceneRecall(scene: 1)], fades: [fade])

        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(ShowCard.self, from: data)

        XCTAssertEqual(decoded.fades.count, 1)
        XCTAssertEqual(decoded.fades[0].durationSeconds, 2.0)
        XCTAssertEqual(decoded.fades[0].steps, 10)
    }

    func testShowCard_codableRoundtrip_allActionKinds() throws {
        let actions: [ShowAction] = [
            .sceneRecall(scene: 1),
            .dcaFader(group: 1, value: 0.5),
            .dcaMute(group: 2, muted: true),
            .channelFader(channel: .channel(1), value: 0.75),
            .channelMute(channel: .channel(2), muted: false),
            .channelGain(channel: .channel(3), gainDb: 12.0),
            ShowAction(id: UUID().uuidString, kind: .wait(seconds: 1.0)),
        ]
        let card = ShowCard(name: "All Actions", actions: actions)

        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(ShowCard.self, from: data)

        XCTAssertEqual(decoded.actions.count, 7)
    }

    func testShowCard_codableRoundtrip_emptyActions() throws {
        let card = ShowCard(name: "Empty", actions: [])

        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(ShowCard.self, from: data)

        XCTAssertTrue(decoded.actions.isEmpty)
    }

    func testShowCard_codableRoundtrip_showArray() throws {
        let cards = ShowCard.defaultShows()
        let data = try JSONEncoder().encode(cards)
        let decoded = try JSONDecoder().decode([ShowCard].self, from: data)

        XCTAssertEqual(decoded.count, cards.count)
        for i in cards.indices {
            XCTAssertEqual(decoded[i].name, cards[i].name)
            XCTAssertEqual(decoded[i].actions.count, cards[i].actions.count)
        }
    }

    // MARK: - ShowRunner with defaultShows

    func testRunner_executeDefaultShows_allShowsWithoutError() async throws {
        let shows = ShowCard.defaultShows()
        for show in shows {
            sender.reset()
            try await runner.execute(card: show)
            XCTAssertFalse(sender.sentMessages.isEmpty, "\(show.name) should send messages")
        }
    }

    func testRunner_executeAllOutputs_sendsSceneRecallAnd8DcaMutes() async throws {
        let shows = ShowCard.defaultShows()
        try await runner.execute(card: shows[0])

        // 1 scene recall + 8 DCA mute messages
        XCTAssertEqual(sender.sentMessages.count, 9)
        XCTAssertTrue(sender.sentAddresses.contains("/scene/1/load"))
        let dcaAddresses = sender.sentAddresses.filter { $0.hasPrefix("/dca/") && $0.hasSuffix("/on") }
        XCTAssertEqual(dcaAddresses.count, 8)
    }

    // MARK: - ShowAction.Delay

    func testDelay_secondsIsPreserved() {
        let action = ShowAction(id: "test", kind: .wait(seconds: 2.5))
        if case .wait(let seconds) = action.kind {
            XCTAssertEqual(seconds, 2.5)
        } else {
            XCTFail("Expected wait action")
        }
    }

    // MARK: - ShowCard Description Backward Compatibility

    func testShowCard_notesProperty_setsDescription() {
        let card = ShowCard(name: "Test", actions: [], notes: "My notes")
        XCTAssertEqual(card.description, "My notes")
    }

    func testShowCard_notesProperty_getsDescription() {
        let card = ShowCard(
            id: UUID().uuidString,
            name: "Test",
            actions: [],
            description: "My description"
        )
        XCTAssertEqual(card.notes, "My description")
    }

    // MARK: - ShowProgress

    func testShowProgress_initialStatus() {
        let progress = ShowProgress(cardId: "1", actionId: "a1", status: .running, error: nil)
        XCTAssertEqual(progress.status, .running)
        XCTAssertNil(progress.error)
    }

    func testShowProgress_completedWithError() {
        let progress = ShowProgress(cardId: "1", actionId: "a1", status: .failed, error: "Timeout")
        XCTAssertEqual(progress.status, .failed)
        XCTAssertEqual(progress.error, "Timeout")
    }
}
