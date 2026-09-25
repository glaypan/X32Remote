import XCTest
@testable import X32RemoteCore

/// 测试 RemoteState 数据模型 (与 Sources/X32RemoteCore/Model/RemoteState.swift 的真实 API 对应)
final class RemoteStateTests: XCTestCase {

    // MARK: - 通道状态测试

    func testChannelStateDefaults() {
        let channel = ChannelState()

        XCTAssertEqual(channel.fader, 0.0)
        XCTAssertFalse(channel.mute)
        XCTAssertNil(channel.x32Name)
        XCTAssertEqual(channel.displayName, "未命名")
    }

    func testChannelStateDisplayNameFallback() {
        var channel = ChannelState()
        channel.x32Name = "Vocal"
        XCTAssertEqual(channel.displayName, "Vocal")

        channel.label = "Lead Vocal"
        XCTAssertEqual(channel.displayName, "Lead Vocal", "label 优先于 x32Name")
    }

    func testChannelFaderValueStorage() {
        var channel = ChannelState()
        channel.fader = 0.75
        channel.mute = true
        channel.dcaMask = 0b0000_0101

        XCTAssertEqual(channel.fader, 0.75)
        XCTAssertTrue(channel.mute)
        XCTAssertEqual(channel.dcaMask, 5)
    }

    // MARK: - DCA 成员关系测试

    func testDcaStatesWithMembers() {
        var state = RemoteState()
        state.channels["ch/01"] = ChannelState(fader: 0.5, dcaMask: 0b0000_0011) // DCA 1+2
        state.channels["ch/02"] = ChannelState(fader: 0.5, dcaMask: 0b0000_0001) // DCA 1
        state.channels["ch/03"] = ChannelState(fader: 0.5, dcaMask: 0)           // 无 DCA

        let dcaDict = state.dcaStatesWithMembers()

        let dca1 = dcaDict["dca/01"]
        XCTAssertNotNil(dca1)
        XCTAssertEqual(dca1?.memberKeys.count, 2)
        XCTAssertTrue(dca1?.memberKeys.contains("ch/01") ?? false)
        XCTAssertTrue(dca1?.memberKeys.contains("ch/02") ?? false)

        let dca2 = dcaDict["dca/02"]
        XCTAssertEqual(dca2?.memberKeys, ["ch/01"])

        XCTAssertNil(dcaDict["dca/08"], "没有成员的 DCA 不应出现")
    }

    func testDcaStateDisplayName() {
        let dca = DcaState(index: 3)
        XCTAssertEqual(dca.displayName, "DCA 3")

        var named = DcaState(index: 3, x32Name: "Band")
        XCTAssertEqual(named.displayName, "Band")
        named.label = " rhythm "
        XCTAssertEqual(named.displayName, " rhythm ")
    }

    // MARK: - 演出卡片测试

    func testShowCardCreation() {
        let card = ShowCard(
            id: "card-1",
            name: "Opening",
            actions: [
                .sceneRecall(scene: 1),
                .channelFader(channel: .channel(1), value: 0.75),
                .delay(seconds: 1.0),
                .channelMute(channel: .channel(2), muted: true)
            ]
        )

        XCTAssertEqual(card.id, "card-1")
        XCTAssertEqual(card.name, "Opening")
        XCTAssertEqual(card.actions.count, 4)
    }

    func testShowActionKinds() {
        let dcaMute = ShowAction.dcaMute(group: 1, muted: true)
        if case .dcaMute(let index, let mute) = dcaMute.kind {
            XCTAssertEqual(index, 1)
            XCTAssertTrue(mute)
        } else {
            XCTFail("Expected dcaMute")
        }

        let scene = ShowAction.sceneRecall(scene: 5)
        if case .sceneRecall(let sceneNum, _) = scene.kind {
            XCTAssertEqual(sceneNum, 5)
        } else {
            XCTFail("Expected sceneRecall")
        }

        let wait = ShowAction.delay(seconds: 0.5)
        if case .wait(let seconds) = wait.kind {
            XCTAssertEqual(seconds, 0.5, accuracy: 0.0001)
        } else {
            XCTFail("Expected wait")
        }
    }

    func testDefaultShows() {
        let shows = ShowCard.defaultShows()
        XCTAssertFalse(shows.isEmpty)
        XCTAssertTrue(shows.allSatisfy { !$0.actions.isEmpty })
    }

    // MARK: - RemoteState 集成测试

    func testRemoteStateInitialization() {
        let state = RemoteState()

        // 初始状态应为空,由 OSC 查询逐步填充
        XCTAssertTrue(state.channels.isEmpty)
        XCTAssertTrue(state.dcas.isEmpty)
        XCTAssertTrue(state.buses.isEmpty)
        XCTAssertTrue(state.fxs.isEmpty)
    }

    func testRemoteStateCodableRoundTrip() throws {
        var state = RemoteState()
        state.channels["ch/01"] = ChannelState(fader: 0.75, mute: true, x32Name: "Vocal")
        state.dcas["dca/01"] = DcaState(index: 1, x32Name: "Band")
        state.buses["bus/01"] = BusState(index: 1, x32Name: "Monitor")
        state.fxs["fx/1"] = FxState(index: 1, x32Name: "Reverb")

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RemoteState.self, from: data)

        XCTAssertEqual(decoded, state)
    }

    // MARK: - 电平表转换测试

    func testMeterToLevel() {
        XCTAssertEqual(OscAddresses.meterToLevel(-32768.0), 0.0, "-∞ 应映射为 0")

        let levelAtMinus60 = OscAddresses.meterToLevel(-60.0)
        XCTAssertEqual(levelAtMinus60, 0.0, accuracy: 0.001)

        let levelAtMinus30 = OscAddresses.meterToLevel(-30.0)
        XCTAssertEqual(levelAtMinus30, 0.5, accuracy: 0.001)

        XCTAssertEqual(OscAddresses.meterToLevel(0.0), 1.0, accuracy: 0.001)
        XCTAssertEqual(OscAddresses.meterToLevel(5.0), 1.0, "超过 0 dB 应钳位为 1 (削波)")
    }
}
