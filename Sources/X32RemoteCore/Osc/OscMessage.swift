/// OSC 消息
///
/// 表示一条完整的 OSC (Open Sound Control) 消息,包含地址和参数
public struct OscMessage: Sendable, Equatable {
    /// OSC 地址路径
    ///
    /// 必须以 "/" 开头,例如 "/ch/01/mix/fader"
    public let address: String
    
    /// 参数列表
    public let args: [OscArgument]
    
    /// 创建 OSC 消息
    ///
    /// - Parameters:
    ///   - address: OSC 地址路径(必须以 "/" 开头)
    ///   - args: 参数列表(默认为空)
    public init(address: String, args: [OscArgument] = []) {
        self.address = address
        self.args = args
    }
}
