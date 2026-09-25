import Foundation

/// Executes ShowCard actions and fades against an X32/M32 mixer
public final class ShowRunner: @unchecked Sendable {
    private let sender: OscSending
    private let stateProvider: StateProviding

    public var onProgress: ((Double) -> Void)?

    public init(sender: OscSending, stateProvider: StateProviding) {
        self.sender = sender
        self.stateProvider = stateProvider
    }

    public func execute(card: ShowCard) async throws {
        let actionCount = card.actions.count
        let fadeStepCount = card.fades.reduce(0) { $0 + max($1.steps, 1) }
        let totalSteps = actionCount + fadeStepCount
        guard totalSteps > 0 else {
            onProgress?(1.0)
            return
        }

        var completedSteps = 0
        for action in card.actions {
            try Task.checkCancellation()
            try await executeAction(action)
            completedSteps += 1
            onProgress?(Double(completedSteps) / Double(totalSteps))
        }

        for fade in card.fades {
            try Task.checkCancellation()
            try await executeFade(fade) {
                completedSteps += 1
                self.onProgress?(Double(completedSteps) / Double(totalSteps))
            }
        }
    }

    private func executeAction(_ action: ShowAction) async throws {
        switch action.kind {
        case .sceneRecall(let scene, let waitMs):
            try await sender.send(address: OscAddresses.sceneRecall(scene), args: [])
            if let waitMs, waitMs > 0 {
                try await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
            }
        case .dcaFader(let index, let value, _, _):
            try await sender.send(address: OscAddresses.dcaFader(index), args: [.float(Float(value))])
        case .dcaMute(let index, let mute):
            try await sender.send(address: OscAddresses.dcaMute(index), args: [.int(mute ? 0 : 1)])
        case .channelFader(let channelKey, let value, _, _):
            guard let channel = channelNumber(channelKey) else { return }
            try await sender.send(address: OscAddresses.channelFader(channel), args: [.float(Float(value))])
        case .channelMute(let channelKey, let mute):
            guard let channel = channelNumber(channelKey) else { return }
            try await sender.send(address: OscAddresses.channelMute(channel), args: [.int(mute ? 0 : 1)])
        case .channelGain(let channelKey, let value, _, _):
            guard let channel = channelNumber(channelKey) else { return }
            let normalized = min(max((value + 12.0) / 72.0, 0.0), 1.0)
            try await sender.send(address: OscAddresses.channelGain(channel), args: [.float(Float(normalized))])
        case .busSend(let channelKey, let sendIndex, let value, _, _):
            guard let channel = channelNumber(channelKey) else { return }
            try await sender.send(address: OscAddresses.busSend(channel, sendIndex), args: [.float(Float(value))])
        case .eqBand, .lowCut, .comp, .delay:
            // 尚未实现的功能,静默跳过 (与 UI 层的展示保持一致)
            return
        case .wait(let seconds):
            guard seconds > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    private func channelNumber(_ key: String) -> Int? {
        Int(key.split(separator: "/").last ?? "")
    }

    private func executeFade(_ fade: ShowFade, onStepComplete: () -> Void) async throws {
        let steps = max(fade.steps, 1)
        let stepDuration = max(fade.durationSeconds, 0) / Double(steps)
        let targetValue = value(of: fade.action.kind)

        for step in 0..<steps {
            try Task.checkCancellation()
            let progress = Double(step + 1) / Double(steps)
            let currentValue = fade.fromValue + (targetValue - fade.fromValue) * progress
            try await executeAction(replacingValue(in: fade.action, with: currentValue))
            onStepComplete()
            if step < steps - 1 {
                try await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            }
        }
    }

    private func value(of kind: ShowActionKind) -> Double {
        switch kind {
        case .dcaFader(_, let value, _, _), .channelFader(_, let value, _, _),
             .channelGain(_, let value, _, _), .busSend(_, _, let value, _, _):
            return value
        default:
            return 0
        }
    }

    private func replacingValue(in action: ShowAction, with value: Double) -> ShowAction {
        switch action.kind {
        case .dcaFader(let index, _, let mode, let fadeMs):
            return ShowAction(id: action.id, kind: .dcaFader(index: index, value: value, mode: mode, fadeMs: fadeMs))
        case .channelFader(let key, _, let mode, let fadeMs):
            return ShowAction(id: action.id, kind: .channelFader(channelKey: key, value: value, mode: mode, fadeMs: fadeMs))
        case .channelGain(let key, _, let mode, let fadeMs):
            return ShowAction(id: action.id, kind: .channelGain(channelKey: key, value: value, mode: mode, fadeMs: fadeMs))
        case .busSend(let key, let sendIndex, _, let mode, let fadeMs):
            return ShowAction(id: action.id, kind: .busSend(channelKey: key, sendIndex: sendIndex, value: value, mode: mode, fadeMs: fadeMs))
        default:
            return action
        }
    }
}
