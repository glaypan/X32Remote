import Foundation
import Network

public final class X32Client: @unchecked Sendable, MixerWriting {
    public enum Status: Equatable, Sendable { case disconnected, connecting, connected, failed(String) }

    /// 桥接引擎：回声抑制 / 回读分类 / 链路状态 / 事件流。
    ///
    /// App 一端连真台时，这里承担的是"服务端桥接"的角色：
    /// 本地虚拟台面立即生效，同时把写入转发出去，并把回读同步回来。
    public let bridge = BridgeEngine()

    /// 卡片引擎的冲突保护接入点（由 App 层注入）。
    ///
    /// 手动操作正在被卡片驱动的通道时，只冻结该路，卡片其余动作继续。
    public weak var showEngine: ShowEngine?

    /// /xinfo 探测结果 (自动发现用)
    public struct XinfoReply: Equatable, Sendable {
        public let host: String
        public let name: String
        public let model: String
        public let version: String
    }

    public let host: String
    public let port: UInt16
    public var onStatus: ((Status) -> Void)?
    public var onMessage: ((OscMessage) -> Void)?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "x32remote.udp")
    private var timer: DispatchSourceTimer?
    private var meterTimer: DispatchSourceTimer?

    // state 可能同时在 client 队列 (收包/发包) 和主线程 (乐观更新) 被访问,必须加锁
    private let stateLock = NSLock()
    private var _state = RemoteState()

    public init(host: String, port: UInt16 = UInt16(defaultX32OscPort)) {
        self.host = host
        self.port = port
    }

    /// 线程安全的状态快照
    public var state: RemoteState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    private func updateState(_ mutate: (inout RemoteState) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }
        mutate(&_state)
    }

    public func connect() {
        disconnect()
        onStatus?(.connecting)
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        connection = c
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready: self?.ready()
            case .failed(let e): self?.onStatus?(.failed(e.localizedDescription))
            default: break
            }
        }
        c.start(queue: queue)
        receive(c)
    }

    private func ready() {
        onStatus?(.connected)
        send(OscMessage(address: "/xinfo"))
        // 订阅台面变更推送: 真机上别人推推子/按静音会实时回传 (模拟器同样兼容)
        send(OscMessage(address: OscAddresses.subscribe, args: [.int(1)]))
        // 首次电平表请求 (模拟器据此加入推送列表)
        send(OscMessage(address: OscAddresses.metersChannels))
        // 保活：真台 10 秒无续期会取消遥控链接，协议规范定的是 5 秒
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now() + 5, repeating: 5)
        timer?.setEventHandler { [weak self] in
            self?.send(OscMessage(address: OscAddresses.keepalive), source: .sync)
            // 顺带检查桥接连路是否已长期无回包
            self?.bridge.refreshStaleness()
        }
        timer?.resume()
        // 电平表轮询: 真机上 /meters/1 每次请求返回一帧,以 150ms 周期刷新
        meterTimer = DispatchSource.makeTimerSource(queue: queue)
        meterTimer?.schedule(deadline: .now() + 0.15, repeating: 0.15)
        meterTimer?.setEventHandler { [weak self] in
            self?.send(OscMessage(address: OscAddresses.metersChannels))
        }
        meterTimer?.resume()
        queryInitialState()
    }

    public func disconnect() {
        // 礼貌退订台面变更推送 (连接存在时才发)
        if connection != nil {
            send(OscMessage(address: OscAddresses.subscribe, args: [.int(0)]))
        }
        meterTimer?.cancel()
        meterTimer = nil
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        onStatus?(.disconnected)
    }

    /// 发送一条 OSC 消息。
    ///
    /// - Parameter source: 写入来源。`manual`（默认）会触发冲突检测：
    ///   若该路正被卡片渐变驱动，只冻结这一路，卡片其余动作继续执行。
    public func send(_ message: OscMessage, source: WriteSource = .manual) {
        let target = OscAddressParser.parse(message.address)

        // 1) 手动接管检查（卡片驱动中的通道被用户在手机上抢走）
        if source.triggersConflictCheck, let target {
            showEngine?.checkManualTakeover(kind: target.kind, idx: target.idx, origin: .local)
        }

        guard let c = connection else { return }

        // 2) 登记回声抑制记录：这一路的值是我们刚写出去的
        if let target, let value = OscAddressParser.numericValue(message) {
            bridge.noteForward(kind: target.kind, idx: target.idx, value: value)
        }

        do {
            let data = try OscCodec.encode(message)
            c.send(content: data, completion: .contentProcessed { [weak self] e in
                if let e {
                    self?.onStatus?(.failed(e.localizedDescription))
                }
            })
            // 乐观更新: 本地虚拟台面立即生效,等待调音台回包校准
            apply(message)
        } catch {
            onStatus?(.failed(error.localizedDescription))
        }
    }

    /// 台面上的一次写入（`MixerWriting` 实现，供卡片引擎调用）
    public func writeValue(kind: String, idx: Int, value: Float, source: WriteSource) {
        guard let address = MixerSpec.address(kind: kind, idx: idx) else { return }
        let arg: OscArgument
        if kind == "ch_dca" {
            arg = .int(Int32(min(max(value, 0), 255)))
        } else if kind.hasSuffix("_on") {
            arg = .int(value != 0 ? 1 : 0)
        } else {
            arg = .float(min(max(value, 0), 1))
        }
        send(OscMessage(address: address, args: [arg]), source: source)
    }

    public func writeRaw(address: String, args: [OscArgument]) {
        send(OscMessage(address: address, args: args), source: .action)
    }

    public func readFader(kind: String, idx: Int) -> Float {
        state.fader(kind: kind, idx: idx)
    }

    public func targetLabel(kind: String, idx: Int) -> String {
        state.targetLabel(kind: kind, idx: idx)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            if let data {
                do {
                    for m in try OscCodec.decodeMessages(data) {
                        self?.handleIncoming(m)
                        self?.onMessage?(m)
                    }
                } catch { }
            }
            if error == nil {
                self?.receive(c)
            }
        }
    }

    /// 真台回读：先判定这是自己的回声还是真台端的变化，再落到本地台面。
    ///
    /// 真台端的变化若命中卡片正在驱动的那一路，会触发手动干预告警
    /// （真台面板被人动了推子 —— 与服务端桥接的回读处理一致）。
    private func handleIncoming(_ m: OscMessage) {
        bridge.noteActivity()

        if let target = OscAddressParser.parse(m.address),
           let value = OscAddressParser.numericValue(m),
           bridge.classify(kind: target.kind, idx: target.idx, value: value) == .remoteChange {
            showEngine?.checkManualTakeover(kind: target.kind, idx: target.idx, origin: .remote)
        }

        apply(m)
    }

    /// 初始状态查询 (一次性拉取全部推子/静音/名称/成员)
    private func queryInitialState() {
        for i in 1...32 {
            let p = "/ch/\(String(format: "%02d", i))"
            for s in ["/mix/fader", "/mix/on", "/config/name"] {
                send(OscMessage(address: p + s), source: .sync)
            }
            // ⚠️ DCA 成员地址以模拟器/桥接规范为准用 mix 段（历史写法 grp 段已不改回）
            send(OscMessage(address: MixerSpec.channelDcaMask(i)), source: .sync)
        }
        // 主输出 Main LR
        send(OscMessage(address: OscAddresses.mainFader), source: .sync)
        send(OscMessage(address: OscAddresses.mainMute), source: .sync)
        send(OscMessage(address: OscAddresses.mainName), source: .sync)
        for i in 1...8 {
            let p = "/dca/\(String(format: "%02d", i))"
            for s in ["/fader", "/on", "/config/name"] {
                send(OscMessage(address: p + s), source: .sync)
            }
        }
        for i in 1...16 {
            let p = "/bus/\(String(format: "%02d", i))"
            for s in ["/mix/fader", "/mix/on", "/config/name"] {
                send(OscMessage(address: p + s), source: .sync)
            }
        }
        // AuxIn / USB / FX Return / Matrix —— 卡片的 fade_all 与 rel_db 会驱动这些分组，
        // 虚拟台面必须先把它们的当前值读回来，否则渐变起点会从 0 开始。
        for (group, n) in [("auxin", 6), ("usb", 2), ("fxret", 8), ("mtx", 6)] {
            for i in 1...n {
                let p = "/\(group)/\(String(format: "%02d", i))"
                for s in ["/mix/fader", "/mix/on", "/config/name"] {
                    send(OscMessage(address: p + s), source: .sync)
                }
            }
        }
        for i in 1...4 {
            send(OscMessage(address: "/fx/\(i)/config/name"), source: .sync)
            let r = "/rtn/fx/\(i)"
            for s in ["/mix/fader", "/mix/on"] {
                send(OscMessage(address: r + s), source: .sync)
            }
        }
    }

    // MARK: - 轻量探测 (自动发现)

    /// 向指定主机发送单条 /xinfo,等待回复。
    ///
    /// 与完整 connect() 不同,此方法不会查询任何初始状态,
    /// 适合对整个子网做快速扫描 (每个 IP 只发 1 条消息)。
    public static func probeXinfo(host: String,
                                  port: UInt16 = UInt16(defaultX32OscPort),
                                  timeout: TimeInterval = 0.6,
                                  completion: @escaping @Sendable (XinfoReply?) -> Void) {
        let queue = DispatchQueue(label: "x32remote.probe")

        guard let oscPort = NWEndpoint.Port(rawValue: port) else {
            completion(nil)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: oscPort, using: .udp)

        // 用一个 Sendable 状态盒持有可变状态,使下方闭包只需捕获不可变引用。
        // 所有回调都跑在同一个串行 queue 上,故内部无需加锁。
        let probe = ProbeState(connection: connection, completion: completion)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let data = try? OscCodec.encode(OscMessage(address: "/xinfo")) {
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
            case .failed, .cancelled:
                probe.finish(nil)
            default:
                break
            }
        }

        connection.receiveMessage { data, _, _, error in
            guard let data, error == nil else {
                probe.finish(nil)
                return
            }
            let reply = (try? OscCodec.decodeMessages(data))?.compactMap { message -> XinfoReply? in
                guard message.address == "/xinfo" else { return nil }
                let strings = message.args.compactMap { arg -> String? in
                    if case .string(let s) = arg { return s }
                    return nil
                }
                // /xinfo 回复: [IP, 自定义名称, 型号, 固件版本]
                guard strings.count >= 3 else { return nil }
                return XinfoReply(host: strings[0],
                                  name: strings[1].isEmpty ? strings[2] : strings[1],
                                  model: strings[2],
                                  version: strings.count > 3 ? strings[3] : "")
            }.first
            probe.finish(reply)
        }

        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            probe.finish(nil)
        }
    }

    // MARK: - 状态解析

    private func auxState(group: String, key: String, index: Int) -> AuxState {
        let st = state
        switch group {
        case "auxin": return st.auxins[key] ?? AuxState(index: index)
        case "usb":   return st.usbs[key] ?? AuxState(index: index)
        case "fxret": return st.fxRets[key] ?? AuxState(index: index)
        default:      return st.mtxs[key] ?? AuxState(index: index)
        }
    }

    private func apply(_ m: OscMessage) {
        guard let v = m.args.first else { return }
        let number: Double? = { switch v { case .float(let x): return Double(x); case .int(let x): return Double(x); default: return nil } }()

        // Meter blobs (/meters/1): meterFloats 已跳过数量字段, [0..31]=ch01..ch32 电平
        if m.address.hasPrefix("/meters/") {
            guard case .blob(let blob) = v else { return }
            let values = OscAddresses.meterFloats(from: blob)
            guard !values.isEmpty else { return }
            for i in 0..<min(32, values.count) {
                let key = String(format: "ch/%02d", i + 1)
                let level = OscAddresses.meterToLevel(values[i])
                updateState { s in
                    var c = s.channels[key] ?? ChannelState()
                    c.level = level
                    s.channels[key] = c
                }
            }
            return
        }

        // DCA messages
        if m.address.hasPrefix("/dca/") {
            let p = m.address.split(separator: "/"); guard p.count >= 3, let i = Int(p[1]) else { return }
            var d = state.dcas["dca/\(p[1])"] ?? DcaState(index: i)
            if p[2] == "fader", let n = number { d.fader = n }
            if p[2] == "on", let n = number { d.mute = n == 0 }
            if p[2] == "config" { if case .string(let s) = v { d.x32Name = s } }
            updateState { $0.dcas["dca/\(p[1])"] = d }
            return
        }

        // Bus messages
        if m.address.hasPrefix("/bus/") {
            let p = m.address.split(separator: "/"); guard p.count >= 3, let i = Int(p[1]) else { return }
            var b = state.buses["bus/\(p[1])"] ?? BusState(index: i)
            if m.address.hasSuffix("/fader"), let n = number { b.fader = n }
            if m.address.hasSuffix("/on"), let n = number { b.mute = n == 0 }
            if p.last == "name", case .string(let s) = v { b.x32Name = s }
            updateState { $0.buses["bus/\(p[1])"] = b }
            return
        }

        // FX return messages
        if m.address.hasPrefix("/rtn/fx/") {
            let p = m.address.split(separator: "/"); guard p.count >= 4, let i = Int(p[2]) else { return }
            var f = state.fxs["fx/\(i)"] ?? FxState(index: i)
            if m.address.hasSuffix("/fader"), let n = number { f.fader = n }
            if m.address.hasSuffix("/on"), let n = number { f.mute = n == 0 }
            updateState { $0.fxs["fx/\(i)"] = f }
            return
        }

        // FX config messages
        if m.address.hasPrefix("/fx/") && m.address.hasSuffix("/name") {
            let p = m.address.split(separator: "/"); guard p.count >= 3, let i = Int(p[1]) else { return }
            var f = state.fxs["fx/\(i)"] ?? FxState(index: i)
            if case .string(let s) = v { f.x32Name = s }
            updateState { $0.fxs["fx/\(i)"] = f }
            return
        }

        // FX param messages
        if m.address.contains("/par/") {
            let p = m.address.split(separator: "/"); guard p.count >= 4, let i = Int(p[1]) else { return }
            var f = state.fxs["fx/\(i)"] ?? FxState(index: i)
            if let n = number { f.params[String(p[3])] = n }
            updateState { $0.fxs["fx/\(i)"] = f }
            return
        }

        // AuxIn / USB / FX Return / Matrix —— 卡片的 fade_all 与 rel_db 会写入这些分组，
        // 虚拟台面必须能记下它们的当前值。
        let p = m.address.split(separator: "/")
        let auxGroups: Set<String> = ["auxin", "usb", "fxret", "mtx"]
        if p.count >= 4, auxGroups.contains(String(p[0])) {
            var digits = String(p[1])
            while let last = digits.last, last == "L" || last == "R" { digits.removeLast() }
            guard let idx = Int(digits) else { return }
            let group = String(p[0])
            let key = "\(group)/\(String(format: "%02d", idx))"
            var s = auxState(group: group, key: key, index: idx)
            if m.address.hasSuffix("/fader"), let n = number { s.fader = n }
            if m.address.hasSuffix("/on"), let n = number { s.mute = n == 0 }
            if p.last == "name", case .string(let x) = v { s.x32Name = x }
            updateState { st in
                switch group {
                case "auxin": st.auxins[key] = s
                case "usb":   st.usbs[key] = s
                case "fxret": st.fxRets[key] = s
                default:      st.mtxs[key] = s
                }
            }
            return
        }

        // Channel messages
        guard p.count >= 4 else { return }
        let key = p[1] == "main" ? "main/st" : "\(p[1])/\(p[2])"
        var s = state.channels[key] ?? ChannelState()

        // Basic channel params
        if m.address.hasSuffix("/fader"), let n = number { s.fader = n }
        if m.address.hasSuffix("/on"), let n = number { s.mute = n == 0 }
        if m.address.hasSuffix("/trim"), let n = number { s.gain = n }
        if m.address.hasSuffix("/name"), case .string(let x) = v { s.x32Name = x }
        if m.address.hasSuffix("/dca"), let n = number { s.dcaMask = Int(n) }

        // EQ
        if m.address.contains("/eq/") {
            if s.eq == nil { s.eq = EqState(on: false, bands: (0..<4).map { _ in EqBand() }) }
            guard var eq = s.eq else { return }
            if m.address.hasSuffix("/eq/on"), let n = number { eq.on = n != 0 }
            if p.count >= 6, let bandIndex = Int(p[5]), bandIndex >= 1, bandIndex <= 4 {
                let idx = bandIndex - 1
                if idx >= eq.bands.count { return }
                if p[6] == "type", let n = number { eq.bands[idx].type = Int(n) }
                if p[6] == "freq", let n = number { eq.bands[idx].freq = n }
                if p[6] == "gain", let n = number { eq.bands[idx].gain = n }
                if p[6] == "q", let n = number { eq.bands[idx].q = n }
            }
            s.eq = eq
        }

        // Low Cut
        if m.address.contains("/lc/") {
            if s.lowCut == nil { s.lowCut = LowCutState() }
            guard var lc = s.lowCut else { return }
            if m.address.hasSuffix("/lc/on"), let n = number { lc.on = n != 0 }
            if m.address.hasSuffix("/lc/freq"), let n = number { lc.freq = n }
            if m.address.hasSuffix("/lc/slope"), let n = number { lc.slope = Int(n) }
            s.lowCut = lc
        }

        // Compressor
        if m.address.contains("/comp/") {
            if s.comp == nil { s.comp = CompState() }
            guard var comp = s.comp else { return }
            if m.address.hasSuffix("/comp/on"), let n = number { comp.on = n != 0 }
            if m.address.hasSuffix("/comp/threshold"), let n = number { comp.threshold = n }
            if m.address.hasSuffix("/comp/ratio"), let n = number { comp.ratio = n }
            if m.address.hasSuffix("/comp/knee"), let n = number { comp.knee = n }
            if m.address.hasSuffix("/comp/makeup_gain"), let n = number { comp.makeupGain = n }
            if m.address.hasSuffix("/comp/attack"), let n = number { comp.attack = n }
            if m.address.hasSuffix("/comp/hold"), let n = number { comp.hold = n }
            if m.address.hasSuffix("/comp/release"), let n = number { comp.release = n }
            s.comp = comp
        }

        updateState { $0.channels[key] = s }
    }
}

/// `probeXinfo` 的一次性状态盒。
///
/// 之所以抽成类型而不是局部函数:局部函数被并发闭包捕获时必须标注 `@Sendable`,
/// 而它又捕获了可变状态,二者无法同时满足(Swift 6 模式下直接报错)。
/// 改为引用类型后,闭包只捕获这个不可变引用即可。
/// 所有访问都发生在同一个串行 queue 上,故标注 `@unchecked Sendable`。
private final class ProbeState: @unchecked Sendable {
    private let connection: NWConnection
    private let completion: @Sendable (X32Client.XinfoReply?) -> Void
    private var finished = false

    init(connection: NWConnection, completion: @escaping @Sendable (X32Client.XinfoReply?) -> Void) {
        self.connection = connection
        self.completion = completion
    }

    func finish(_ reply: X32Client.XinfoReply?) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        completion(reply)
    }
}
