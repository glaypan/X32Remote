import Foundation
import Network

public final class X32Client: @unchecked Sendable {
    public enum Status: Equatable, Sendable { case disconnected, connecting, connected, failed(String) }

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
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now() + 9, repeating: 9)
        timer?.setEventHandler { [weak self] in self?.send(OscMessage(address: OscAddresses.keepalive)) }
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

    public func send(_ message: OscMessage) {
        guard let c = connection else { return }
        do {
            let data = try OscCodec.encode(message)
            c.send(content: data, completion: .contentProcessed { [weak self] e in
                if let e {
                    self?.onStatus?(.failed(e.localizedDescription))
                }
            })
            // 乐观更新: 本地立即生效,等待调音台回包校准
            apply(message)
        } catch {
            onStatus?(.failed(error.localizedDescription))
        }
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            if let data {
                do {
                    for m in try OscCodec.decodeMessages(data) {
                        self?.apply(m)
                        self?.onMessage?(m)
                    }
                } catch { }
            }
            if error == nil {
                self?.receive(c)
            }
        }
    }

    /// 初始状态查询 (一次性拉取全部推子/静音/名称)
    private func queryInitialState() {
        for i in 1...32 {
            let p = "/ch/\(String(format: "%02d", i))"
            for s in ["/mix/fader", "/mix/on", "/config/name", "/grp/dca"] {
                send(OscMessage(address: p + s))
            }
        }
        // 主输出 Main LR
        send(OscMessage(address: OscAddresses.mainFader))
        send(OscMessage(address: OscAddresses.mainMute))
        send(OscMessage(address: OscAddresses.mainName))
        for i in 1...8 {
            let p = "/dca/\(String(format: "%02d", i))"
            for s in ["/fader", "/on", "/config/name"] {
                send(OscMessage(address: p + s))
            }
        }
        for i in 1...16 {
            let p = "/bus/\(String(format: "%02d", i))"
            for s in ["/mix/fader", "/mix/on", "/config/name"] {
                send(OscMessage(address: p + s))
            }
        }
        for i in 1...4 {
            send(OscMessage(address: "/fx/\(i)/config/name"))
            let r = "/rtn/fx/\(i)"
            for s in ["/mix/fader", "/mix/on"] {
                send(OscMessage(address: r + s))
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
        var finished = false
        guard let oscPort = NWEndpoint.Port(rawValue: port) else {
            completion(nil)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: oscPort, using: .udp)

        // 所有回调都在同一个串行 queue 上执行,finished 无需额外加锁
        func finish(_ reply: XinfoReply?) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(reply)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let data = try? OscCodec.encode(OscMessage(address: "/xinfo")) {
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }

        connection.receiveMessage { data, _, _, error in
            guard let data, error == nil else {
                finish(nil)
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
            finish(reply)
        }

        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            finish(nil)
        }
    }

    // MARK: - 状态解析

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

        // Channel messages
        let p = m.address.split(separator: "/"); guard p.count >= 4 else { return }
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
