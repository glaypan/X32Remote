import XCTest
@testable import X32RemoteCore

/// `/api/fxcaps` 的解析与"可写性"语义。
///
/// 口径与服务端 `ConsoleProfile.fx_param_caps()` + 模拟器 `test_wing_params.py`
/// 的 F 层一致：`all=true` 全可写；`all=false` 时按槽查清单，**空清单 = 一项都不能写**；
/// 槽号缺失（服务端不该出现）按放行处理，避免把功能误关。
final class FxParamCapsTests: XCTestCase {

    private func decode(_ json: String) throws -> FxParamCaps {
        try FxParamCapsAPI.decode(Data(json.utf8))
    }

    // MARK: - 解析

    func testX32AllWritable() throws {
        let c = try decode(#"{"console":"x32","all":true,"slots":{}}"#)
        XCTAssertTrue(c.all)
        XCTAssertEqual(c.console, "x32")
        XCTAssertTrue(c.slots.isEmpty)
        XCTAssertTrue(c.allows(slot: 1, par: 99), "X32 没有未标定的概念")
        XCTAssertEqual(c.blockedCount(slot: 1, pars: [1, 2, 3]), 0)
    }

    func testWingSlotList() throws {
        // 真实形状：WING ROOM 槽实测可写 [1,2,3,4,5,7,8,9,10,11,12,13,14,15,16]（缺 par06）
        let c = try decode("""
        {"console":"wing","all":false,"slots":{
          "1":[1,2,3,4,5,7,8,9,10,11,12,13,14,15,16],
          "2":[],
          "3":[1]
        }}
        """)
        XCTAssertFalse(c.all)
        XCTAssertEqual(c.slots[1]?.count, 15)
        XCTAssertTrue(c.allows(slot: 1, par: 1))
        XCTAssertFalse(c.allows(slot: 1, par: 6), "par06 在 WING 的 ROOM 上没有地址")
        XCTAssertEqual(c.blockedCount(slot: 1, pars: Array(1...16)), 1)

        // 空清单 = 这个槽一个参数都不能写（如 WING 上只做延迟/调制、参数名对不上的算法）
        XCTAssertTrue(c.slots[2]?.isEmpty == true)
        XCTAssertFalse(c.allows(slot: 2, par: 1))
        XCTAssertEqual(c.blockedCount(slot: 2, pars: [1, 2]), 2)
    }

    func testMissingSlotIsPermissive() throws {
        // 槽号缺失（服务端把 1..N 都列全了，缺键说明对端不是本服务）→ 放行，不整片灰掉
        let c = try decode(#"{"console":"wing","all":false,"slots":{"1":[1]}}"#)
        XCTAssertTrue(c.allows(slot: 9, par: 42))
        XCTAssertEqual(c.blockedCount(slot: 9, pars: [1, 2, 3]), 0)
    }

    func testMissingAllFieldDefaultsToWritable() throws {
        // 老服务端没有这个接口 / 字段 → 不能误灰
        let c = try decode(#"{"slots":{"1":[]}}"#)
        XCTAssertTrue(c.all)
        XCTAssertTrue(c.allows(slot: 1, par: 1))
    }

    func testGarbageBodyIsAllWritable() throws {
        // 非 JSON 或形状不对：一律降级成"全可写"，绝不因为解析失败禁用滑杆
        let c = try FxParamCapsAPI.decode(Data("not json".utf8))
        XCTAssertTrue(c.all)
        XCTAssertTrue(c.allows(slot: 1, par: 1))
    }

    func testUnrestrictedDefault() {
        XCTAssertTrue(FxParamCaps.unrestricted.all)
        XCTAssertTrue(FxParamCaps.unrestricted.allows(slot: 1, par: 1))
        XCTAssertEqual(FxParamCaps.unrestricted.blockedCount(slot: 1, pars: [1, 2]), 0)
    }

    // MARK: - 地址

    func testBaseURL() {
        XCTAssertEqual(FxParamCapsAPI.baseURL(host: "192.168.1.9", port: 8080)?.absoluteString,
                       "http://192.168.1.9:8080")
    }
}
