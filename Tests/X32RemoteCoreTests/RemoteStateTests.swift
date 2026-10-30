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

    // MARK: - FX 槽状态测试 (v1.6 效果库全量标定新增字段)

    func testFxStateDefaults() {
        let fx = FxState(index: 3)
        XCTAssertNil(fx.algoType, "没查过 /fx/3/type 就不知道装了什么, 别猜")
        XCTAssertTrue(fx.on, "默认按启用渲染, 免得界面谎报关闭")
        XCTAssertEqual(fx.mix, 0.25)
        XCTAssertTrue(fx.params.isEmpty)
        XCTAssertEqual(fx.displayName, "FX 3")
    }

    func testFxStateParamKeyFormat() {
        // X32Client 按 OSC 原始段存参数 (两位补零字符串 "01"…"12")。
        // FxDetailView 读值用 String(format: "%02d", spec.p) 与之配对 ——
        // 这个约定三处 (写入/读取/服务端) 必须一致, 这里锁死。
        var fx = FxState(index: 1)
        fx.params["01"] = 0.5
        fx.params["12"] = 3.5
        XCTAssertEqual(fx.params["01"], 0.5)
        XCTAssertEqual(fx.params["12"], 3.5)
    }

    func testFxStateCodableRoundTrip() throws {
        var fx = FxState(index: 1, x32Name: "Reverb")
        fx.algoType = "HALL"
        fx.on = false
        fx.mix = 0.4
        fx.params["02"] = 2.4
        let decoded = try JSONDecoder().decode(FxState.self, from: JSONEncoder().encode(fx))
        XCTAssertEqual(decoded, fx)
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
