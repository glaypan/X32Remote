import Foundation

/// OSC 消息编解码器
///
/// 提供 OSC (Open Sound Control) 消息的二进制编码和解码功能
public enum OscCodec {
    /// OSC 编码错误
    public enum CodecError: Error {
        case invalidAddress
        case invalidData
    }
    
    /// 将 OSC 消息编码为二进制数据
    ///
    /// - Parameter message: 待编码的 OSC 消息
    /// - Returns: 编码后的二进制数据(大端序,4字节对齐)
    /// - Throws: `CodecError.invalidAddress` 如果地址格式无效
    ///
    /// 二进制格式:
    /// - 地址字符串(以 null 结尾,填充至 4 字节边界)
    /// - 类型标签字符串(以 "," 开头,以 null 结尾,填充至 4 字节边界)
    /// - 参数数据(大端序编码,每个参数 4 字节)
    public static func encode(_ message: OscMessage) throws -> Data {
        guard !message.address.isEmpty && message.address.hasPrefix("/") else {
            throw CodecError.invalidAddress
        }
        
        var data = Data()
        
        // 编码地址 (null 结尾,填充至 4 字节边界)
        data.append(contentsOf: message.address.utf8)
        data.append(0)
        while data.count % 4 != 0 {
            data.append(0)
        }
        
        // 编码类型标签
        var typeTags = ","
        for arg in message.args {
            switch arg {
            case .int: typeTags.append("i")
            case .float: typeTags.append("f")
            case .string: typeTags.append("s")
            case .bool(let value): typeTags.append(value ? "T" : "F")
            case .blob: typeTags.append("b")
            }
        }
        data.append(contentsOf: typeTags.utf8)
        data.append(0)
        while data.count % 4 != 0 {
            data.append(0)
        }
        
        // 编码参数
        for arg in message.args {
            switch arg {
            case .int(let value):
                var bigEndian = value.bigEndian
                data.append(contentsOf: withUnsafeBytes(of: &bigEndian) { Data($0) })
            case .float(let value):
                var bigEndian = value.bitPattern.bigEndian
                data.append(contentsOf: withUnsafeBytes(of: &bigEndian) { Data($0) })
            case .string(let value):
                data.append(contentsOf: value.utf8)
                data.append(0)
                while data.count % 4 != 0 {
                    data.append(0)
                }
            case .bool:
                break  // T 和 F 不占用参数数据空间
            case .blob(let blob):
                // 'b' 类型: 4 字节长度 + 数据 + 补齐至 4 字节边界
                var size = Int32(blob.count).bigEndian
                data.append(contentsOf: withUnsafeBytes(of: &size) { Data($0) })
                data.append(blob)
                while data.count % 4 != 0 {
                    data.append(0)
                }
            }
        }
        
        return data
    }
    
    /// 从二进制数据解码 OSC 消息
    ///
    /// - Parameter data: 编码的二进制数据
    /// - Returns: 解码后的 OSC 消息
    /// - Throws: `CodecError.invalidData` 如果数据格式无效
    public static func decode(_ data: Data) throws -> OscMessage {
        guard !data.isEmpty else {
            throw CodecError.invalidData
        }
        
        var offset = 0
        
        // 解码地址
        guard let addressEnd = data[offset...].firstIndex(of: 0) else {
            throw CodecError.invalidData
        }
        guard let address = String(data: data[offset..<addressEnd], encoding: .utf8) else {
            throw CodecError.invalidData
        }
        offset = ((addressEnd - data.startIndex + 1) + 3) / 4 * 4
        
        // 解码类型标签
        guard offset < data.count else {
            throw CodecError.invalidData
        }
        guard let typeTagEnd = data[offset...].firstIndex(of: 0) else {
            throw CodecError.invalidData
        }
        guard let typeTag = String(data: data[offset..<typeTagEnd], encoding: .utf8),
              typeTag.hasPrefix(",") else {
            throw CodecError.invalidData
        }
        offset = ((typeTagEnd - data.startIndex + 1) + 3) / 4 * 4
        
        // 解码参数
        var args: [OscArgument] = []
        for char in typeTag.dropFirst() {
            switch char {
            case "i":
                guard offset + 4 <= data.count else { throw CodecError.invalidData }
                let value = data[offset..<offset+4].withUnsafeBytes {
                    Int32(bigEndian: $0.load(as: Int32.self))
                }
                args.append(.int(value))
                offset += 4
            case "f":
                guard offset + 4 <= data.count else { throw CodecError.invalidData }
                let bitPattern = data[offset..<offset+4].withUnsafeBytes {
                    UInt32(bigEndian: $0.load(as: UInt32.self))
                }
                args.append(.float(Float(bitPattern: bitPattern)))
                offset += 4
            case "s":
                guard let strEnd = data[offset...].firstIndex(of: 0) else {
                    throw CodecError.invalidData
                }
                guard let str = String(data: data[offset..<strEnd], encoding: .utf8) else {
                    throw CodecError.invalidData
                }
                args.append(.string(str))
                offset = ((strEnd - data.startIndex + 1) + 3) / 4 * 4
            case "T":
                args.append(.bool(true))
            case "F":
                args.append(.bool(false))
            case "b":
                guard offset + 4 <= data.count else { throw CodecError.invalidData }
                let size = Int(Int32(bigEndian: data[offset..<offset+4].withUnsafeBytes {
                    $0.load(as: Int32.self)
                }))
                offset += 4
                guard size >= 0, offset + size <= data.count else { throw CodecError.invalidData }
                args.append(.blob(data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + size))))
                offset = (offset + size + 3) / 4 * 4
            default:
                throw CodecError.invalidData
            }
        }

        return OscMessage(address: address, args: args)
    }

    /// 从二进制数据解码一组 OSC 消息
    ///
    /// 自动识别单条消息和 OSC Bundle (`#bundle`,含 timetag 与多个子元素)。
    /// X32/M32 调音台通常会以 Bundle 形式返回多条状态消息。
    ///
    /// - Parameter data: 编码的二进制数据
    /// - Returns: 解码出的所有 OSC 消息
    /// - Throws: `CodecError.invalidData` 如果数据格式无效
    public static func decodeMessages(_ data: Data) throws -> [OscMessage] {
        guard data.count >= 8 else {
            throw CodecError.invalidData
        }

        // OSC Bundle 以 "#bundle\0" 开头
        let bundleHeader = Data("#bundle".utf8)
        if data.startIndex + 7 <= data.endIndex, data[data.startIndex..<(data.startIndex + 7)] == bundleHeader {
            return try decodeBundle(data)
        }

        return [try decode(data)]
    }

    /// 解码 OSC Bundle: "#bundle\0" + 8 字节 timetag + 若干 [长度(4字节) + 元素]
    private static func decodeBundle(_ data: Data) throws -> [OscMessage] {
        var offset = 16  // "#bundle\0" 8 字节 + timetag 8 字节
        var messages: [OscMessage] = []

        while offset + 4 <= data.count {
            let size = Int(Int32(bigEndian: data[(data.startIndex + offset)..<(data.startIndex + offset + 4)].withUnsafeBytes {
                $0.load(as: Int32.self)
            }))
            offset += 4

            guard size > 0, offset + size <= data.count else { break }

            let element = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + size))
            if let subMessages = try? decodeMessages(element) {
                messages.append(contentsOf: subMessages)
            }
            offset += size
        }

        return messages
    }
}
