public struct ChannelKey: Hashable, Sendable {
    public let rawValue: String
    
    private init(rawValue: String) {
        self.rawValue = rawValue
    }
    
    public static func channel(_ num: Int) -> ChannelKey {
        ChannelKey(rawValue: String(format: "ch/%02d", num))
    }
    
    public var number: Int? {
        Int(rawValue.split(separator: "/").last ?? "")
    }
}

