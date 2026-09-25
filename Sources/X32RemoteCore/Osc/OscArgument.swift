import Foundation

/// OSC (Open Sound Control) 参数类型
///
/// 支持 X32/M32 调音台通信所需的基本 OSC 数据类型
public enum OscArgument: Sendable {
    case int(Int32)
    case float(Float)
    case string(String)
    case bool(Bool)
    /// 二进制数据块(OSC 类型标签 'b'),用于 /meters 电平表数据等
    case blob(Data)
}

extension OscArgument: Equatable {}
