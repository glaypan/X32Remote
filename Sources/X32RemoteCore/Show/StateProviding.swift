import Foundation

/// Protocol for providing current mixer state
public protocol StateProviding: Sendable {
    func channelFader(for key: ChannelKey) -> Float
    func dcaFader(for group: Int) -> Float
}
