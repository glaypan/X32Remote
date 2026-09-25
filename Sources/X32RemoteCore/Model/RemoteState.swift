import Foundation

public struct SendState: Codable, Equatable, Sendable { public var level: Double = 0; public var on = false }
public struct EqBand: Codable, Equatable, Sendable { public var type = 2; public var freq = 1000.0; public var gain = 0.0; public var q = 1.0 }
public struct EqState: Codable, Equatable, Sendable { public var on = false; public var bands: [EqBand] = [] }
public struct LowCutState: Codable, Equatable, Sendable { public var on = false; public var freq = 80.0; public var slope = 12 }
public struct CompState: Codable, Equatable, Sendable { public var on = false; public var mode = 0; public var det = 0; public var env = 0; public var threshold = 0.0; public var ratio = 2.0; public var knee = 0.0; public var makeupGain = 0.0; public var attack = 0.0; public var hold = 0.0; public var release = 0.0; public var position = 0 }
public struct ChannelState: Codable, Equatable, Sendable { public var fader = 0.0; public var mute = false; public var x32Name: String?; public var label: String?; public var gain: Double?; public var sends: [String: SendState]?; public var dcaMask: Int?; public var eq: EqState?; public var lowCut: LowCutState?; public var comp: CompState?; public var delay: Double?; public var level: Float = 0; public init(fader: Double = 0, mute: Bool = false, x32Name: String? = nil, label: String? = nil, gain: Double? = nil, sends: [String: SendState]? = nil, dcaMask: Int? = nil, eq: EqState? = nil, lowCut: LowCutState? = nil, comp: CompState? = nil, delay: Double? = nil, level: Float = 0) { self.fader=fader; self.mute=mute; self.x32Name=x32Name; self.label=label; self.gain=gain; self.sends=sends; self.dcaMask=dcaMask; self.eq=eq; self.lowCut=lowCut; self.comp=comp; self.delay=delay; self.level=level }; public var displayName: String { label ?? x32Name ?? "未命名" } }
public struct DcaState: Codable, Equatable, Sendable { public var index: Int; public var fader = 0.0; public var mute = false; public var x32Name: String?; public var label: String?; public var memberKeys: [String] = []; public init(index: Int, x32Name: String? = nil) { self.index=index; self.x32Name=x32Name }; public var displayName: String { label ?? x32Name ?? "DCA \(index)" } }
public struct BusState: Codable, Equatable, Sendable { public var index: Int; public var fader = 0.0; public var mute = false; public var x32Name: String?; public var label: String?; public init(index: Int, x32Name: String? = nil) { self.index=index; self.x32Name=x32Name }; public var displayName: String { label ?? x32Name ?? "Bus \(index)" } }
public struct FxState: Codable, Equatable, Sendable { public var index: Int; public var fader = 0.0; public var mute = false; public var x32Name: String?; public var label: String?; public var params: [String: Double] = [:]; public init(index: Int, x32Name: String? = nil) { self.index=index; self.x32Name=x32Name }; public var displayName: String { label ?? x32Name ?? "FX \(index)" } }
public struct RemoteState: Codable, Equatable, Sendable { public var channels: [String: ChannelState] = [:]; public var dcas: [String: DcaState] = [:]; public var buses: [String: BusState] = [:]; public var fxs: [String: FxState] = [:]; public init(channels: [String: ChannelState] = [:], dcas: [String: DcaState] = [:], buses: [String: BusState] = [:], fxs: [String: FxState] = [:]) { self.channels=channels; self.dcas=dcas; self.buses=buses; self.fxs=fxs }; public func dcaStatesWithMembers() -> [String: DcaState] { var result = dcas.mapValues { var d=$0; d.memberKeys=[]; return d }; for (key, channel) in channels { guard let mask=channel.dcaMask else { continue }; for i in 1...8 where mask & (1 << (i-1)) != 0 { let k="dca/\(String(format: "%02d",i))"; var d=result[k] ?? DcaState(index:i); d.memberKeys.append(key); result[k]=d } }; return result } }

public enum ValueMode: String, Codable, Sendable { case absolute, relative }
public enum ShowProgressStatus: String, Codable, Sendable { case running, completed, failed, cancelled }
public struct ShowProgress: Equatable, Sendable { public let cardId: String; public let actionId: String; public let status: ShowProgressStatus; public let error: String? }
public enum ShowActionKind: Codable, Equatable, Sendable { case sceneRecall(scene: Int, waitMs: Int?); case dcaFader(index: Int, value: Double, mode: ValueMode, fadeMs: Int?); case dcaMute(index: Int, mute: Bool); case channelFader(channelKey: String, value: Double, mode: ValueMode, fadeMs: Int?); case channelMute(channelKey: String, mute: Bool); case channelGain(channelKey: String, value: Double, mode: ValueMode, fadeMs: Int?); case busSend(channelKey: String, sendIndex: Int, value: Double, mode: ValueMode, fadeMs: Int?); case eqBand(channelKey: String, band: Int, field: String, value: Double, mode: ValueMode); case lowCut(channelKey: String, field: String, value: CodableValue); case comp(channelKey: String, field: String, value: CodableValue, mode: ValueMode); case delay(channelKey: String, value: Double, mode: ValueMode, fadeMs: Int?); case wait(seconds: Double) }
public struct CodableValue: Codable, Equatable, Sendable { public let number: Double?; public let bool: Bool?; public init(_ n: Double) { number=n; bool=nil }; public init(_ b: Bool) { number=nil; bool=b } }
public struct ShowAction: Codable, Equatable, Identifiable, Sendable { public let id: String; public let kind: ShowActionKind; public init(id: String, kind: ShowActionKind) { self.id=id; self.kind=kind } }
public struct ShowFade: Codable, Equatable, Sendable {
    public let action: ShowAction
    public let fromValue: Double
    public let durationSeconds: Double
    public let steps: Int
    
    public init(action: ShowAction, fromValue: Double, durationSeconds: Double, steps: Int) {
        self.action = action
        self.fromValue = fromValue
        self.durationSeconds = durationSeconds
        self.steps = steps
    }
}

public struct ShowCard: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var description: String?
    public var color: String?
    public var actions: [ShowAction]
    public var fades: [ShowFade]
    public var waitAfterSceneMs: Int?
    public var continueOnError: Bool = false
    
    public init(id: String, name: String, actions: [ShowAction], description: String? = nil, color: String? = nil, fades: [ShowFade] = [], waitAfterSceneMs: Int? = nil) {
        self.id = id
        self.name = name
        self.actions = actions
        self.description = description
        self.color = color
        self.fades = fades
        self.waitAfterSceneMs = waitAfterSceneMs
    }
    
    // Convenience constructors with UUID auto-generation
    public init(name: String, actions: [ShowAction]) {
        self.init(id: UUID().uuidString, name: name, actions: actions)
    }
    
    public init(name: String, actions: [ShowAction], notes: String) {
        self.init(id: UUID().uuidString, name: name, actions: actions, description: notes)
    }
    
    public init(name: String, actions: [ShowAction], fades: [ShowFade]) {
        self.init(id: UUID().uuidString, name: name, actions: actions, fades: fades)
    }
    
    // Backward compatibility computed property
    public var notes: String? {
        get { description }
        set { description = newValue }
    }

    public static func defaultShows() -> [ShowCard] {
        [
            ShowCard(name: "All Outputs", actions: [
                .sceneRecall(scene: 1),
                .dcaMute(group: 1, muted: true),
                .dcaMute(group: 2, muted: true),
                .dcaMute(group: 3, muted: true),
                .dcaMute(group: 4, muted: true),
                .dcaMute(group: 5, muted: true),
                .dcaMute(group: 6, muted: true),
                .dcaMute(group: 7, muted: true),
                .dcaMute(group: 8, muted: true),
            ], notes: "Reset all DCA groups from scene 1"),
            ShowCard(name: "Drums & Percussion", actions: [
                .sceneRecall(scene: 2)
            ], notes: "Recall drums scene"),
            ShowCard(name: "Vocals Focus", actions: [
                .sceneRecall(scene: 3)
            ], notes: "Recall vocals scene"),
            ShowCard(id: UUID().uuidString, name: "晚宴模式",
                     actions: [
                        .channelMute(channel: .channel(1), muted: true),
                        .channelMute(channel: .channel(2), muted: true),
                     ],
                     description: "静音话筒,10 秒内把电脑音频(通道 15)从 75% 渐弱到 30%",
                     fades: [
                        ShowFade(action: .channelFader(channel: .channel(15), value: 0.30),
                                 fromValue: 0.75, durationSeconds: 10, steps: 20)
                     ]),
        ]
    }
}

extension ShowAction {
    public static func sceneRecall(scene: Int) -> ShowAction {
        ShowAction(id: UUID().uuidString, kind: .sceneRecall(scene: scene, waitMs: nil))
    }
    public static func dcaFader(group: Int, value: Double) -> ShowAction {
        ShowAction(id: UUID().uuidString, kind: .dcaFader(index: group, value: value, mode: .absolute, fadeMs: nil))
    }
    public static func dcaMute(group: Int, muted: Bool) -> ShowAction {
        ShowAction(id: UUID().uuidString, kind: .dcaMute(index: group, mute: muted))
    }
    public static func channelFader(channel: ChannelKey, value: Double) -> ShowAction {
        ShowAction(id: UUID().uuidString, kind: .channelFader(channelKey: channel.rawValue, value: value, mode: .absolute, fadeMs: nil))
    }
    public static func channelMute(channel: ChannelKey, muted: Bool) -> ShowAction {
        ShowAction(id: UUID().uuidString, kind: .channelMute(channelKey: channel.rawValue, mute: muted))
    }
    public static func channelGain(channel: ChannelKey, gainDb: Double) -> ShowAction {
        ShowAction(id: UUID().uuidString, kind: .channelGain(channelKey: channel.rawValue, value: gainDb, mode: .absolute, fadeMs: nil))
    }
    public static func busSend(channel: ChannelKey, bus: Int, value: Double) -> ShowAction {
        ShowAction(id: UUID().uuidString, kind: .busSend(channelKey: channel.rawValue, sendIndex: bus, value: value, mode: .absolute, fadeMs: nil))
    }
    public static func delay(seconds: Double) -> ShowAction {
        ShowAction(id: UUID().uuidString, kind: .wait(seconds: seconds))
    }
}
