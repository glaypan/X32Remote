import XCTest
@testable import X32RemoteCore

/// 配对码解析：与服务端 `x32sim/pair.py` 同一套规则，双方各自实现，
/// 所以这里逐条对齐"坏值必须拒绝"，避免两端对同一个码给出不同结论。
final class PairCodeTests: XCTestCase {

    func testParsePairCode() {
        let code = PairCode.parse("x32remote://pair?v=1&host=192.168.50.57&osc=10025&web=8090")
        XCTAssertEqual(code, PairCode(host: "192.168.50.57", oscPort: 10025, webPort: 8090))
    }

    func testParsePairCodeWithoutWebPort() {
        let code = PairCode.parse("x32remote://pair?v=1&host=10.0.0.9&osc=10023")
        XCTAssertEqual(code?.host, "10.0.0.9")
        XCTAssertEqual(code?.oscPort, 10023)
        XCTAssertNil(code?.webPort)
    }

    /// 现场最常见的动作：拿 App 去扫电脑端那张**浏览器**二维码
    func testParseBrowserURL() {
        let code = PairCode.parse("http://192.168.50.57:8080/")
        XCTAssertEqual(code, PairCode(host: "192.168.50.57", oscPort: 10023, webPort: 8080))
    }

    func testParseBrowserURLWithoutPort() {
        let code = PairCode.parse("https://mixer.local/")
        XCTAssertEqual(code?.host, "mixer.local")
        XCTAssertEqual(code?.oscPort, 10023)
        XCTAssertNil(code?.webPort)
    }

    func testParseHostPortAndBareHost() {
        XCTAssertEqual(PairCode.parse("192.168.1.9:10025"),
                       PairCode(host: "192.168.1.9", oscPort: 10025))
        XCTAssertEqual(PairCode.parse(" 192.168.1.9 "),
                       PairCode(host: "192.168.1.9", oscPort: 10023))
        XCTAssertEqual(PairCode.parse("192.168.1.9/"),
                       PairCode(host: "192.168.1.9", oscPort: 10023))
    }

    func testRejectsLoopback() {
        XCTAssertNil(PairCode.parse("127.0.0.1:10023"))
        XCTAssertNil(PairCode.parse("localhost:10023"))
        XCTAssertNil(PairCode.parse("x32remote://pair?v=1&host=127.0.0.1&osc=10023"))
        XCTAssertNil(PairCode.parse("http://127.0.0.1:8080/"))
    }

    func testRejectsBadValues() {
        XCTAssertNil(PairCode.parse(""))
        XCTAssertNil(PairCode.parse("javascript:alert(1)"))
        XCTAssertNil(PairCode.parse("ftp://192.168.1.5/"))
        XCTAssertNil(PairCode.parse("192.168.1.5:70000"))
        XCTAssertNil(PairCode.parse("256.1.1.1"))
        XCTAssertNil(PairCode.parse("192.168.1.5:0"))
        XCTAssertNil(PairCode.parse("x32remote://pair?v=1&host=192.168.1.5&osc=abc"))
        XCTAssertNil(PairCode.parse("http://192.168.1.5:99999/"))
        XCTAssertNil(PairCode.parse(String(repeating: "a", count: 220)))
    }

    func testToleratesWhitespace() {
        XCTAssertEqual(PairCode.parse("  http://192.168.50.57:8080/  "),
                       PairCode(host: "192.168.50.57", oscPort: 10023, webPort: 8080))
    }

    func testSummaryIsReadable() {
        XCTAssertEqual(PairCode(host: "192.168.1.5", oscPort: 10023, webPort: 8080).summary,
                       "192.168.1.5:10023（网页 8080）")
        XCTAssertEqual(PairCode(host: "192.168.1.5", oscPort: 10025).summary, "192.168.1.5:10025")
    }
}
