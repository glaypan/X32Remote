import Foundation

public struct SendState: Codable, Equatable, Sendable { public var level: Double = 0; public var on = false }
public struct EqBand: Codable, Equatable, Sendable { public var type = 2; public var freq = 1000.0; public var gain = 0.0; public var q = 1.0 }
public struct EqState: Codable, Equatable, Sendable { public var on = false; public var bands: [EqBand] = [] }
public struct LowCutState: Codable, Equatable, Sendable { public var on = false; public var freq = 80.0; public var slope = 12 }
public struct CompState: Codable, Equatable, Sendable { public var on = false; public var mode = 0; public var det = 0; public var env = 0; public var threshold = 0.0; public var ratio = 2.0; public var knee = 0.0; public var makeupGain = 0.0; public var attack = 0.0; public var hold = 0.0; public var release = 0.0; public var position = 0 }
public struct ChannelState: Codable, Equatable, Sendable { public var fader = 0.0; public var mute = false; public var x32Name: String?; public var label: String?; public var gain: Double?; public var sends: [String: SendState]?; public var dcaMask: Int?; public var eq: EqState?; public var lowCut: LowCutState?; public var comp: CompState?; public var delay: Double?; public var level: Float = 0; public init(fader: Double = 0, mute: Bool = false, x32Name: String? = nil, label: String? = nil, gain: Double? = nil, sends: [String: SendState]? = nil, dcaMask: Int? = nil, eq: EqState? = nil, lowCut: LowCutState? = nil, comp: CompState? = nil, delay: Double? = nil, level: Float = 0) { self.fader=fader; self.mute=mute; self.x32Name=x32Name; self.label=label; self.gain=gain; self.sends=sends; self.dcaMask=dcaMask; self.eq=eq; self.lowCut=lowCut; self.comp=comp; self.delay=delay; self.level=level }; public var displayName: String { label ?? x32Name ?? "未命名" } }
public struct DcaState: Codable, Equatable, Sendable { public var index: Int; public var fader = 0.0; public var mute = false; public var x32Name: String?; public var label: String?; public var memberKeys: [String] = []; public init(index: Int, x32Name: String? = nil) { self.index=index; self.x32Name=x32Name }; public var displayName: String { label ?? x32Name ?? "DCA \(index)" } }
public struct BusState: Codable, Equatable, Sendable { public var index: Int; public var fader = 0.0; public var mute = false; public var x32Name: String?; public var label: String?; public init(index: Int, x32Name: String? = nil) { self.index=index; self.x32Name=x32Name }; public var displayName: String { label ?? x32Name ?? "Bus \(index)" } }
public struct FxState: Codable, Equatable, Sendable { public var index: Int; public var fader = 0.0; public var mute = false; public var x32Name: String?; public var label: String?; public var params: [String: Double] = [:]; public var algoType: String?; public var on = true; public var mix = 0.25; public init(index: Int, x32Name: String? = nil) { self.index=index; self.x32Name=x32Name }; public var displayName: String { label ?? x32Name ?? "FX \(index)" } }
/// AuxIn / USB / FX Return / Matrix 等"辅助分组"的通用状态。
///
/// 桥接引擎的 `fade_all` 与 `rel_db` 需要驱动这些分组，因此它们必须与
/// ch/bus/dca 一样能被本地虚拟台面记录。
public struct AuxState: Codable, Equatable, Sendable {
    public var index: Int
    public var fader = 0.0
    public var mute = false
    public var x32Name: String?
    public var label: String?
    public init(index: Int, x32Name: String? = nil) { self.index = index; self.x32Name = x32Name }
    public var displayName: String { label ?? x32Name ?? "\(index)" }
}

public struct RemoteState: Codable, Equatable, Sendable {
    public var channels: [String: ChannelState] = [:]
    public var dcas: [String: DcaState] = [:]
    public var buses: [String: BusState] = [:]
    public var fxs: [String: FxState] = [:]
    public var auxins: [String: AuxState] = [:]
    public var usbs: [String: AuxState] = [:]
    public var fxRets: [String: AuxState] = [:]
    public var mtxs: [String: AuxState] = [:]
    /// 通道处理参数的通用取回表：键 `"ch/01/trim"` / `"bus/03/eq2_g"` / `"main/01/pan"`。
    ///
    /// 为什么不塞进 ChannelState: 各组能力不同（Bus 6 段 EQ、FX 返回连 EQ 都没有），
    /// 每加一个参数就要加一个字段，而且 App 端得跟着改结构体。这里用"分组/路号/字段"
    /// 三元组做键，配合 ParamTable 的地址反查，任何新参数**零改动**就能显示与调节。
    /// 键里的 idx 对 main 固定写 01（内部编号从 1 起，与 OSC 地址一致）。
    public var params: [String: Double] = [:]

    public init(channels: [String: ChannelState] = [:],
                dcas: [String: DcaState] = [:],
                buses: [String: BusState] = [:],
                fxs: [String: FxState] = [:],
                auxins: [String: AuxState] = [:],
                usbs: [String: AuxState] = [:],
                fxRets: [String: AuxState] = [:],
                mtxs: [String: AuxState] = [:],
                params: [String: Double] = [:]) {
        self.channels = channels
        self.dcas = dcas
        self.buses = buses
        self.fxs = fxs
        self.auxins = auxins
        self.usbs = usbs
        self.fxRets = fxRets
        self.mtxs = mtxs
        self.params = params
    }

    /// 参数键（统一入口，避免各处手拼字符串拼错）
    public static func paramKey(_ group: String, _ idx: Int, _ field: String) -> String {
        String(format: "%@/%02d/%@", group, idx, field)
    }

    public func param(_ group: String, _ idx: Int, _ field: String) -> Double? {
        params[RemoteState.paramKey(group, idx, field)]
    }

    public func dcaStatesWithMembers() -> [String: DcaState] { var result = dcas.mapValues { var d=$0; d.memberKeys=[]; return d }; for (key, channel) in channels { guard let mask=channel.dcaMask else { continue }; for i in 1...8 where mask & (1 << (i-1)) != 0 { let k="dca/\(String(format: "%02d",i))"; var d=result[k] ?? DcaState(index:i); d.memberKeys.append(key); result[k]=d } }; return result } }
