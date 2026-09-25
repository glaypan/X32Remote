import XCTest
@testable import X32RemoteCore

/// 测试 OSC 地址生成和 dB 映射
final class OscAddressesTests: XCTestCase {
    
    // MARK: - 地址生成测试
    
    func testChannelFaderAddress() {
        XCTAssertEqual(
            OscAddresses.channelFader(1),
            "/ch/01/mix/fader"
        )
        XCTAssertEqual(
            OscAddresses.channelFader(32),
            "/ch/32/mix/fader"
        )
    }
    
    func testChannelMuteAddress() {
        XCTAssertEqual(
            OscAddresses.channelMute(1),
            "/ch/01/mix/on"
        )
    }
    
    func testChannelNameAddress() {
        XCTAssertEqual(
            OscAddresses.channelName(1),
            "/ch/01/config/name"
        )
    }
    
    func testDcaFaderAddress() {
        // DCA 地址使用两位补零,与状态查询和状态键保持一致
        XCTAssertEqual(
            OscAddresses.dcaFader(1),
            "/dca/01/fader"
        )
        XCTAssertEqual(
            OscAddresses.dcaFader(8),
            "/dca/08/fader"
        )
    }

    func testDcaMuteAddress() {
        XCTAssertEqual(
            OscAddresses.dcaMute(1),
            "/dca/01/on"
        )
    }

    func testMeterToLevel() {
        // -32768 表示 -∞ → 电平 0
        XCTAssertEqual(OscAddresses.meterToLevel(-32768), 0)
        // -60 dB → 电平 0
        XCTAssertEqual(OscAddresses.meterToLevel(-60.0), 0, accuracy: 0.0001)
        // 0 dB → 电平 1 (满量程)
        XCTAssertEqual(OscAddresses.meterToLevel(0.0), 1.0, accuracy: 0.0001)
        // -30 dB → 中点
        XCTAssertEqual(OscAddresses.meterToLevel(-30.0), 0.5, accuracy: 0.0001)
        // 超过 0 dB 削波,钳位到 1
        XCTAssertEqual(OscAddresses.meterToLevel(5.0), 1.0, accuracy: 0.0001)
    }
    
    func testSceneRecallAddress() {
        XCTAssertEqual(
            OscAddresses.sceneRecall(1),
            "/scene/1/load"
        )
        XCTAssertEqual(
            OscAddresses.sceneRecall(100),
            "/scene/100/load"
        )
    }
    
    func testKeepaliveAddress() {
        XCTAssertEqual(
            OscAddresses.keepalive,
            "/xremote"
        )
    }
    
    // MARK: - dB 映射测试
    
    func testLinearToDb() {
        // -oo dB (静音)
        XCTAssertEqual(
            OscAddresses.linearToDb(0.0),
            -Double.infinity
        )
        
        // 0 dB (Unity gain)
        XCTAssertEqual(
            OscAddresses.linearToDb(0.75),
            0.0,
            accuracy: 0.1
        )
        
        // +10 dB (最大)
        XCTAssertEqual(
            OscAddresses.linearToDb(1.0),
            10.0,
            accuracy: 0.1
        )
        
        // -10 dB
        let db = OscAddresses.linearToDb(0.5)
        XCTAssertTrue(db < 0.0 && db > -20.0, "Expected around -10 dB")
    }
    
    func testDbToLinear() {
        // -oo dB
        XCTAssertEqual(
            OscAddresses.dbToLinear(-Double.infinity),
            0.0,
            accuracy: 0.001
        )
        
        // 0 dB
        XCTAssertEqual(
            OscAddresses.dbToLinear(0.0),
            0.75,
            accuracy: 0.01
        )
        
        // +10 dB
        XCTAssertEqual(
            OscAddresses.dbToLinear(10.0),
            1.0,
            accuracy: 0.01
        )
        
        // -10 dB: 10^(-10/20) * 0.75 ≈ 0.237
        let linear = OscAddresses.dbToLinear(-10.0)
        XCTAssertEqual(linear, 0.2372, accuracy: 0.01)
    }
    
    func testDbLinearRoundTrip() {
        let testValues: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]
        
        for value in testValues {
            let db = OscAddresses.linearToDb(value)
            let backToLinear = OscAddresses.dbToLinear(db)
            
            if value == 0.0 {
                XCTAssertEqual(backToLinear, 0.0, accuracy: 0.001)
            } else {
                XCTAssertEqual(backToLinear, value, accuracy: 0.01)
            }
        }
    }
    
    func testDbClamping() {
        // 低于 -90 dB 应该被视为静音
        XCTAssertEqual(
            OscAddresses.dbToLinear(-100.0),
            0.0,
            accuracy: 0.001
        )
        
        // 高于 +10 dB 应该被限制
        XCTAssertEqual(
            OscAddresses.dbToLinear(15.0),
            1.0,
            accuracy: 0.01
        )
    }
    
    // MARK: - 边界情况测试
    
    func testChannelIndexBounds() {
        // 有效范围: 1-32
        XCTAssertNoThrow(OscAddresses.channelFader(1))
        XCTAssertNoThrow(OscAddresses.channelFader(32))
        
        // 边界外应该抛出错误或处理
        // (实际实现中需要决定策略)
    }
    
    func testDcaIndexBounds() {
        // 有效范围: 1-8
        XCTAssertNoThrow(OscAddresses.dcaFader(1))
        XCTAssertNoThrow(OscAddresses.dcaFader(8))
    }
    
    func testSceneIndexBounds() {
        // 有效范围: 1-100
        XCTAssertNoThrow(OscAddresses.sceneRecall(1))
        XCTAssertNoThrow(OscAddresses.sceneRecall(100))
    }

    // MARK: - Bus 地址测试

    func testBusSendAddress() {
        XCTAssertEqual(OscAddresses.busSend(1, 1), "/ch/01/mix/01/level")
        XCTAssertEqual(OscAddresses.busSend(16, 16), "/ch/16/mix/16/level")
    }

    func testBusSendOnAddress() {
        XCTAssertEqual(OscAddresses.busSendOn(1, 1), "/ch/01/mix/01/on")
        XCTAssertEqual(OscAddresses.busSendOn(16, 16), "/ch/16/mix/16/on")
    }

    func testBusNameAddress() {
        XCTAssertEqual(OscAddresses.busName(1), "/bus/01/config/name")
        XCTAssertEqual(OscAddresses.busName(16), "/bus/16/config/name")
    }

    func testBusFaderAddress() {
        XCTAssertEqual(OscAddresses.busFader(1), "/bus/01/mix/fader")
        XCTAssertEqual(OscAddresses.busFader(16), "/bus/16/mix/fader")
    }

    func testBusMuteAddress() {
        XCTAssertEqual(OscAddresses.busMute(1), "/bus/01/mix/on")
        XCTAssertEqual(OscAddresses.busMute(16), "/bus/16/mix/on")
    }

    // MARK: - FX 地址测试

    func testFxNameAddress() {
        XCTAssertEqual(OscAddresses.fxName(1), "/fx/1/config/name")
        XCTAssertEqual(OscAddresses.fxName(4), "/fx/4/config/name")
    }

    func testFxFaderAddress() {
        XCTAssertEqual(OscAddresses.fxFader(1), "/rtn/fx/1/mix/fader")
        XCTAssertEqual(OscAddresses.fxFader(4), "/rtn/fx/4/mix/fader")
    }

    func testFxMuteAddress() {
        XCTAssertEqual(OscAddresses.fxMute(1), "/rtn/fx/1/mix/on")
    }

    func testFxParamAddress() {
        XCTAssertEqual(OscAddresses.fxParam(1, 1), "/fx/1/par/01")
        XCTAssertEqual(OscAddresses.fxParam(4, 8), "/fx/4/par/08")
    }

    // MARK: - 电平表地址测试

    func testChannelLevelAddress() {
        XCTAssertEqual(OscAddresses.channelLevel(1), "/ch/01/mix/level")
        XCTAssertEqual(OscAddresses.channelLevel(32), "/ch/32/mix/level")
    }

    // MARK: - 自动发现地址测试

    func testXinfoAddress() {
        XCTAssertEqual(OscAddresses.xinfo, "/xinfo")
    }
}
