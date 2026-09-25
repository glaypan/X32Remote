import Foundation

/// Protocol for sending OSC messages
public protocol OscSending: Sendable {
    func send(address: String, args: [OscArgument]) async throws
}
