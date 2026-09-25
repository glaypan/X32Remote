import XCTest
@testable import X32RemoteCore

final class OscCodecTests: XCTestCase {
    
    // MARK: - 字节往返测试
    
    func testEncodeDecodeRoundTrip() throws {
        let msg = OscMessage(
            address: "/ch/01/mix/fader",
            args: [.float(0.75)]
        )
        
        let encoded = try OscCodec.encode(msg)
        let decoded = try OscCodec.decode(encoded)
        
        XCTAssertEqual(decoded.address, msg.address)
        XCTAssertEqual(decoded.args.count, 1)
        if case .float(let value) = decoded.args[0] {
            XCTAssertEqual(value, 0.75, accuracy: 0.0001)
        } else {
            XCTFail("Expected float argument")
        }
    }
    
    func testEncodeString() throws {
        let msg = OscMessage(
            address: "/ch/01/config/name",
            args: [.string("Vocal")]
        )
        
        let encoded = try OscCodec.encode(msg)
        let decoded = try OscCodec.decode(encoded)
        
        XCTAssertEqual(decoded.address, "/ch/01/config/name")
        if case .string(let value) = decoded.args[0] {
            XCTAssertEqual(value, "Vocal")
        } else {
            XCTFail("Expected string argument")
        }
    }
    
    func testEncodeInt() throws {
        let msg = OscMessage(
            address: "/ch/01/mix/on",
            args: [.int(1)]
        )
        
        let encoded = try OscCodec.encode(msg)
        let decoded = try OscCodec.decode(encoded)
        
        XCTAssertEqual(decoded.address, "/ch/01/mix/on")
        if case .int(let value) = decoded.args[0] {
            XCTAssertEqual(value, 1)
        } else {
            XCTFail("Expected int argument")
        }
    }
    
    // MARK: - 4 字节 Padding 测试
    
    func testAddressPadding() throws {
        // "/test" = 5 bytes, needs 3 bytes padding to reach 8
        let msg = OscMessage(address: "/test", args: [])
        let encoded = try OscCodec.encode(msg)
        
        // Address + null + padding should align to 4-byte boundary
        let addressBytes = encoded.prefix(8)
        XCTAssertEqual(addressBytes.count, 8)
        XCTAssertEqual(addressBytes[5], 0) // null terminator
        XCTAssertEqual(addressBytes[6], 0) // padding
        XCTAssertEqual(addressBytes[7], 0) // padding
    }
    
    func testStringPadding() throws {
        // "ab" = 2 bytes, needs null + 1 byte padding = 4 bytes total
        let msg = OscMessage(
            address: "/test",
            args: [.string("ab")]
        )
        
        let encoded = try OscCodec.encode(msg)
        let decoded = try OscCodec.decode(encoded)
        
        if case .string(let value) = decoded.args[0] {
            XCTAssertEqual(value, "ab")
        } else {
            XCTFail("Expected string argument")
        }
    }
    
    // MARK: - 多参数测试
    
    func testMultipleArguments() throws {
        let msg = OscMessage(
            address: "/test",
            args: [
                .int(42),
                .float(3.14),
                .string("hello")
            ]
        )
        
        let encoded = try OscCodec.encode(msg)
        let decoded = try OscCodec.decode(encoded)
        
        XCTAssertEqual(decoded.address, "/test")
        XCTAssertEqual(decoded.args.count, 3)
        
        if case .int(let i) = decoded.args[0] {
            XCTAssertEqual(i, 42)
        } else {
            XCTFail("Expected int")
        }
        
        if case .float(let f) = decoded.args[1] {
            XCTAssertEqual(f, 3.14, accuracy: 0.001)
        } else {
            XCTFail("Expected float")
        }
        
        if case .string(let s) = decoded.args[2] {
            XCTAssertEqual(s, "hello")
        } else {
            XCTFail("Expected string")
        }
    }
    
    // MARK: - 大端序测试
    
    func testBigEndianFloat() throws {
        let msg = OscMessage(
            address: "/test",
            args: [.float(1.0)]
        )
        
        let encoded = try OscCodec.encode(msg)
        // Float 1.0 in big-endian = 0x3F800000
        // Should appear in the encoded data after address and typetag
        let decoded = try OscCodec.decode(encoded)
        
        if case .float(let value) = decoded.args[0] {
            XCTAssertEqual(value, 1.0, accuracy: 0.0001)
        } else {
            XCTFail("Expected float")
        }
    }
    
    func testBigEndianInt() throws {
        let msg = OscMessage(
            address: "/test",
            args: [.int(256)]
        )
        
        let encoded = try OscCodec.encode(msg)
        let decoded = try OscCodec.decode(encoded)
        
        if case .int(let value) = decoded.args[0] {
            XCTAssertEqual(value, 256)
        } else {
            XCTFail("Expected int")
        }
    }
    
    // MARK: - 边界情况
    
    func testEmptyAddress() throws {
        XCTAssertThrowsError(try OscCodec.encode(
            OscMessage(address: "", args: [])
        ))
    }
    
    func testInvalidAddress() throws {
        XCTAssertThrowsError(try OscCodec.encode(
            OscMessage(address: "no-slash", args: [])
        ))
    }
    
    func testDecodeInvalidData() throws {
        let invalidData = Data([0x00, 0x01, 0x02])
        XCTAssertThrowsError(try OscCodec.decode(invalidData))
    }

    // MARK: - Blob 与 Bundle

    func testBlobRoundTrip() throws {
        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        let msg = OscMessage(address: "/meters/1", args: [.blob(payload)])

        let encoded = try OscCodec.encode(msg)
        let decoded = try OscCodec.decode(encoded)

        XCTAssertEqual(decoded.address, "/meters/1")
        guard case .blob(let data) = decoded.args[0] else {
            XCTFail("Expected blob argument")
            return
        }
        XCTAssertEqual(data, payload)
    }

    func testDecodeMessagesSingle() throws {
        let msg = OscMessage(address: "/ch/01/mix/fader", args: [.float(0.5)])
        let decoded = try OscCodec.decodeMessages(try OscCodec.encode(msg))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].address, "/ch/01/mix/fader")
    }

    func testDecodeBundle() throws {
        // 手工构造一个 bundle: "#bundle\0" + timetag(8字节) + [size + msg] x2
        let m1 = try OscCodec.encode(OscMessage(address: "/ch/01/mix/fader", args: [.float(0.25)]))
        let m2 = try OscCodec.encode(OscMessage(address: "/ch/02/mix/on", args: [.int(1)]))

        var bundle = Data("#bundle".utf8)
        bundle.append(0)                       // 补齐 "#bundle\0" 共 8 字节
        bundle.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1]) // timetag
        bundle.append(contentsOf: withUnsafeBytes(of: Int32(m1.count).bigEndian) { Data($0) })
        bundle.append(m1)
        bundle.append(contentsOf: withUnsafeBytes(of: Int32(m2.count).bigEndian) { Data($0) })
        bundle.append(m2)

        let decoded = try OscCodec.decodeMessages(bundle)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].address, "/ch/01/mix/fader")
        XCTAssertEqual(decoded[1].address, "/ch/02/mix/on")
    }

    func testMeterFloatsParsing() {
        // 首元素为数量 2,随后两个 dB 值: -32768 (-∞) 和 -30.0
        var blob = Data()
        blob.append(contentsOf: withUnsafeBytes(of: Int32(2).bigEndian) { Data($0) })
        let minusInf = Float(-32768.0)
        blob.append(contentsOf: withUnsafeBytes(of: minusInf.bitPattern.bigEndian) { Data($0) })
        let minus30 = Float(-30.0)
        blob.append(contentsOf: withUnsafeBytes(of: minus30.bitPattern.bigEndian) { Data($0) })

        let values = OscAddresses.meterFloats(from: blob)
        // 数量字段被跳过,仅返回电平值
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0], -32768.0)
        XCTAssertEqual(values[1], -30.0, accuracy: 0.001)
    }
}
