import SwiftUI
import Observation
import X32RemoteCore

@Observable
final class AppModel {
    var connectionStatus: ConnectionStatus = .disconnected
    var mixerIP: String = ""
    var mixerPort: UInt16 = 10023

    var channels: [ChannelUI] = []
    var dcaGroups: [DcaUI] = []
    var buses: [BusUI] = []
    var fxProcessors: [FxUI] = []

    /// 演出卡片库（与服务端同一份 JSON 格式，可互相导入导出）
    var showCards: [TimelineCard] = []
    /// 卡片执行进度
    var cardProgress = EngineProgress()

    /// 桥接模式：手机直连真台，App 内部维护虚拟台面并双向同步
    var bridgeEnabled = false {
        didSet {
            UserDefaults.standard.set(bridgeEnabled, forKey: Self.bridgeEnabledKey)
            client?.bridge.setEnabled(bridgeEnabled)
        }
    }
    var bridgeState: BridgeEngine.State = .off
    /// 桥接事件（真台手动干预告警、链路状态变化等），最新在前
    var bridgeEvents: [BridgeEvent] = []

    /// 卡片引擎（连接后创建；未连接时仍可编辑卡片）
    private(set) var showEngine: ShowEngine?

    var isExecutingShow: Bool { cardProgress.isRunning }

    var errorMessage: String?
    var discoveredMixers: [DiscoveredMixer] = []
    var isDiscovering = false

    /// Main LR 在 channels 列表中使用的虚拟 ID
    static let mainChannelId = 33

    var isConnected: Bool {
        if case .connected = connectionStatus { return true }
        return false
    }

    var connectionMessage: String {
        switch connectionStatus {
        case .disconnected: return "未连接"
        case .connecting:   return "连接中..."
        case .connected:    return "已连接"
        case .error(let msg): return msg
        }
    }

    private var client: X32Client?
    private var meterTimer: DispatchSourceTimer?

    // 状态同步节流: 收到 OSC 消息只标记脏,最多每 100ms 重建一次 UI 状态,
    // 避免初始查询 (~300 条消息) 和电平表流 (约 25Hz) 触发全量 SwiftUI diff
    private var stateNeedsSync = false
    private var syncTask: Task<Void, Never>?

    enum ConnectionStatus {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    init() {
        resetToDefaults()
        showCards = Self.loadShowCards()
        bridgeEnabled = UserDefaults.standard.bool(forKey: Self.bridgeEnabledKey)
        mixerIP = UserDefaults.standard.string(forKey: Self.mixerIPKey) ?? ""
        let savedPort = UserDefaults.standard.object(forKey: Self.mixerPortKey) as? Int
        if let savedPort, savedPort > 0, savedPort <= 65535 {
            mixerPort = UInt16(savedPort)
        }
    }

    private func resetToDefaults() {
        channels = (1...32).map { ChannelUI(id: $0, label: "Ch \($0)", level: 0.75, isMuted: false) }
        dcaGroups = (1...8).map { DcaUI(id: $0, label: "DCA \($0)", level: 0.80, isMuted: false) }
        buses = (1...16).map { BusUI(id: $0, label: "Bus \($0)", level: 0.80, isMuted: false) }
        fxProcessors = (1...4).map { FxUI(id: $0, label: "FX \($0)", level: 0.80, isMuted: false, params: [:]) }
    }

    @MainActor
    func connect() async {
        guard !mixerIP.isEmpty else {
            connectionStatus = .error("请输入调音台 IP 地址")
            return
        }

        connectionStatus = .connecting
        UserDefaults.standard.set(mixerIP, forKey: Self.mixerIPKey)
        UserDefaults.standard.set(Int(mixerPort), forKey: Self.mixerPortKey)

        let client = X32Client(host: mixerIP, port: mixerPort)
        client.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .disconnected:
                    self.connectionStatus = .disconnected
                    self.stopMeterPolling()
                case .connecting:
                    self.connectionStatus = .connecting
                case .connected:
                    self.connectionStatus = .connected
                    self.syncState(from: client)
                    self.startMeterPolling()
                case .failed(let msg):
                    self.connectionStatus = .error(msg)
                    self.stopMeterPolling()
                }
            }
        }
        client.onMessage = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                if message.address == OscAddresses.metersChannels {
                    // 电平表 blob 走轻量快速通道,只更新电平,不做全量状态同步
                    self.applyMeterBlob(message)
                } else {
                    self.scheduleStateSync()
                }
            }
        }

        // 卡片引擎：以本次连接作为台面写入通道
        let library = showCards.isEmpty ? TimelineCard.defaults() : showCards
        let engine = ShowEngine(mixer: client, cards: library)
        engine.progressSink = { [weak self] p in
            Task { @MainActor in self?.cardProgress = p }
        }
        engine.eventSink = { [weak client] text in
            // 卡片冲突告警与真台回读告警汇入同一条事件流
            client?.bridge.pushEvent(text, isWarning: true)
        }
        client.showEngine = engine
        self.showEngine = engine
        if showCards.isEmpty { showCards = library }

        // 桥接：回声抑制 / 回读分类 / 链路状态 / 事件流
        client.bridge.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.bridgeEvents.insert(event, at: 0)
                if self.bridgeEvents.count > BridgeEngine.eventLimit {
                    self.bridgeEvents.removeLast(self.bridgeEvents.count - BridgeEngine.eventLimit)
                }
            }
        }
        client.bridge.onStateChange = { [weak self] state in
            Task { @MainActor in self?.bridgeState = state }
        }
        client.bridge.setEnabled(bridgeEnabled)

        client.connect()
        self.client = client
    }

    @MainActor
    func disconnect() {
        stopMeterPolling()
        syncTask?.cancel()
        syncTask = nil
        stateNeedsSync = false
        showEngine?.stopAll()
        showEngine = nil
        cardProgress = EngineProgress()
        client?.bridge.setEnabled(false)
        bridgeState = .off
        client?.disconnect()
        client = nil
        connectionStatus = .disconnected
        resetToDefaults()
    }

    // MARK: - State Sync (节流)

    @MainActor
    private func scheduleStateSync() {
        stateNeedsSync = true
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            self.syncTask = nil
            guard self.stateNeedsSync, let client = self.client else { return }
            self.stateNeedsSync = false
            self.syncState(from: client)
        }
    }

    // MARK: - Meter Polling

    /// 每 500ms 重新订阅一次 /meters/1,调音台会以流的形式持续回发电平 blob
    private func startMeterPolling() {
        stopMeterPolling()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            self?.client?.send(OscMessage(address: OscAddresses.metersChannels))
        }
        t.resume()
        meterTimer = t
    }

    private func stopMeterPolling() {
        meterTimer?.cancel()
        meterTimer = nil
    }

    /// 电平表快速通道: 从 /meters/1 blob 中解析 32 通道电平,直接更新 UI 数组
    @MainActor
    private func applyMeterBlob(_ message: OscMessage) {
        guard case .blob(let blob) = message.args.first else { return }
        let values = OscAddresses.meterFloats(from: blob)
        guard !values.isEmpty else { return }
        for i in 0..<min(32, values.count) {
            let level = OscAddresses.meterToLevel(values[i])
            if let index = channels.firstIndex(where: { $0.id == i + 1 }) {
                channels[index].meterLevel = level
            }
        }
    }

    // MARK: - Auto Discovery

    struct DiscoveredMixer: Identifiable, Equatable {
        let id: String
        let host: String
        let name: String
        let model: String
    }

    /// 自动发现调音台: 对子网内每个 IP 只发送一条轻量 /xinfo 探测 (每批 32 个并发)
    @MainActor
    func discoverMixers() async {
        discoveredMixers = []
        isDiscovering = true
        defer { isDiscovering = false }

        let subnet = extractSubnet(from: mixerIP) ?? Self.localIPv4Subnet() ?? "192.168.0"
        let ips = (1...254).map { "\(subnet).\($0)" }
        var found: [DiscoveredMixer] = []
        let chunkSize = 32

        for start in stride(from: 0, to: ips.count, by: chunkSize) {
            let chunk = Array(ips[start..<min(start + chunkSize, ips.count)])
            let replies = await withTaskGroup(of: (String, X32Client.XinfoReply?).self) { group in
                for ip in chunk {
                    group.addTask {
                        let reply = await withCheckedContinuation { (cont: CheckedContinuation<X32Client.XinfoReply?, Never>) in
                            X32Client.probeXinfo(host: ip) { cont.resume(returning: $0) }
                        }
                        return (ip, reply)
                    }
                }
                var results: [(String, X32Client.XinfoReply?)] = []
                for await r in group { results.append(r) }
                return results
            }
            for (ip, reply) in replies {
                if let reply {
                    found.append(DiscoveredMixer(id: ip, host: ip, name: reply.name, model: reply.model))
                }
            }
        }

        discoveredMixers = found.sorted { $0.host < $1.host }
    }

    private func extractSubnet(from ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    /// 从设备本机 IPv4 地址推断子网 (优先 en0/Wi-Fi),作为 mixerIP 为空时的兜底
    private static func localIPv4Subnet() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var fallback: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var saCopy = sa.pointee
            guard getnameinfo(&saCopy, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }

            let ip = String(cString: host)
            let parts = ip.split(separator: ".")
            guard parts.count == 4 else { continue }
            let subnet = parts.dropLast().joined(separator: ".")

            let name = String(cString: current.pointee.ifa_name)
            if name == "en0" { return subnet }
            if fallback == nil { fallback = subnet }
        }
        return fallback
    }

    // MARK: - State Sync

    @MainActor
    private func syncState(from client: X32Client) {
        let remoteState = client.state

        let sortedKeys = remoteState.channels.keys.sorted()
        channels = sortedKeys.compactMap { key in
            guard key.hasPrefix("ch/"), let ch = remoteState.channels[key] else { return nil }
            let num = Int(key.split(separator: "/").last ?? "") ?? 0
            return ChannelUI(id: num, label: ch.displayName, level: Float(ch.fader), isMuted: ch.mute,
                             eq: ch.eq, lowCut: ch.lowCut, comp: ch.comp, dcaMask: ch.dcaMask,
                             meterLevel: ch.level)
        }
        // 主输出 Main LR 追加在列表末尾
        if let main = remoteState.channels["main/st"] {
            channels.append(ChannelUI(id: Self.mainChannelId,
                                      label: main.x32Name ?? "Main LR",
                                      level: Float(main.fader),
                                      isMuted: main.mute,
                                      meterLevel: 0))
        }

        let dcaDict = remoteState.dcaStatesWithMembers()
        let sortedDcaKeys = dcaDict.keys.sorted()
        dcaGroups = sortedDcaKeys.compactMap { key in
            guard let dca = dcaDict[key] else { return nil }
            return DcaUI(id: dca.index, label: dca.displayName, level: Float(dca.fader), isMuted: dca.mute)
        }

        let sortedBusKeys = remoteState.buses.keys.sorted()
        buses = sortedBusKeys.compactMap { key in
            guard let bus = remoteState.buses[key] else { return nil }
            return BusUI(id: bus.index, label: bus.displayName, level: Float(bus.fader), isMuted: bus.mute)
        }

        let sortedFxKeys = remoteState.fxs.keys.sorted()
        fxProcessors = sortedFxKeys.compactMap { key in
            guard let fx = remoteState.fxs[key] else { return nil }
            return FxUI(id: fx.index, label: fx.displayName, level: Float(fx.fader), isMuted: fx.mute, params: fx.params)
        }
    }

    // MARK: - Channel Level & Mute

    @MainActor
    func setChannelLevel(_ channelId: Int, level: Float) async {
        guard let index = channels.firstIndex(where: { $0.id == channelId }) else { return }
        channels[index].level = level
        let address = channelId == Self.mainChannelId
            ? OscAddresses.mainFader
            : OscAddresses.channelFader(channelId)
        client?.send(OscMessage(address: address, args: [.float(level)]))
    }

    @MainActor
    func toggleChannelMute(_ channelId: Int, isMuted: Bool) async {
        guard let index = channels.firstIndex(where: { $0.id == channelId }) else { return }
        channels[index].isMuted = isMuted
        let address = channelId == Self.mainChannelId
            ? OscAddresses.mainMute
            : OscAddresses.channelMute(channelId)
        client?.send(OscMessage(address: address, args: [.int(isMuted ? 0 : 1)]))
    }

    // MARK: - DCA

    @MainActor
    func setDcaLevel(_ dcaId: Int, level: Float) async {
        guard let index = dcaGroups.firstIndex(where: { $0.id == dcaId }) else { return }
        dcaGroups[index].level = level
        client?.send(OscMessage(address: OscAddresses.dcaFader(dcaId), args: [.float(level)]))
    }

    @MainActor
    func toggleDcaMute(_ dcaId: Int, isMuted: Bool) async {
        guard let index = dcaGroups.firstIndex(where: { $0.id == dcaId }) else { return }
        dcaGroups[index].isMuted = isMuted
        client?.send(OscMessage(address: OscAddresses.dcaMute(dcaId), args: [.int(isMuted ? 0 : 1)]))
    }

    // MARK: - Bus Send

    @MainActor
    func queryBusSends(_ channelId: Int) {
        guard let client else { return }
        let osc = OscAddresses.self
        for bus in 1...16 {
            client.send(OscMessage(address: osc.busSend(channelId, bus)))
            client.send(OscMessage(address: osc.busSendOn(channelId, bus)))
        }
    }

    func setBusSendLevel(_ channelId: Int, bus: Int, level: Float) {
        client?.send(OscMessage(address: OscAddresses.busSend(channelId, bus), args: [.float(level)]))
    }

    @MainActor
    func setBusSendOn(_ channelId: Int, bus: Int, on: Bool) {
        client?.send(OscMessage(address: OscAddresses.busSendOn(channelId, bus), args: [.int(on ? 1 : 0)]))
    }

    @MainActor
    func setBusLevel(_ busId: Int, level: Float) async {
        guard let index = buses.firstIndex(where: { $0.id == busId }) else { return }
        buses[index].level = level
        client?.send(OscMessage(address: OscAddresses.busFader(busId), args: [.float(level)]))
    }

    @MainActor
    func toggleBusMute(_ busId: Int, isMuted: Bool) async {
        guard let index = buses.firstIndex(where: { $0.id == busId }) else { return }
        buses[index].isMuted = isMuted
        client?.send(OscMessage(address: OscAddresses.busMute(busId), args: [.int(isMuted ? 0 : 1)]))
    }

    // MARK: - FX

    @MainActor
    func queryFxDetail(_ fxId: Int) {
        guard let client else { return }
        let osc = OscAddresses.self
        client.send(OscMessage(address: osc.fxFader(fxId)))
        client.send(OscMessage(address: osc.fxMute(fxId)))
        client.send(OscMessage(address: osc.fxName(fxId)))
        // 查询 8 个参数
        for p in 1...8 {
            client.send(OscMessage(address: osc.fxParam(fxId, p)))
        }
    }

    @MainActor
    func setFxLevel(_ fxId: Int, level: Float) async {
        guard let index = fxProcessors.firstIndex(where: { $0.id == fxId }) else { return }
        fxProcessors[index].level = level
        client?.send(OscMessage(address: OscAddresses.fxFader(fxId), args: [.float(level)]))
    }

    @MainActor
    func toggleFxMute(_ fxId: Int, isMuted: Bool) async {
        guard let index = fxProcessors.firstIndex(where: { $0.id == fxId }) else { return }
        fxProcessors[index].isMuted = isMuted
        client?.send(OscMessage(address: OscAddresses.fxMute(fxId), args: [.int(isMuted ? 0 : 1)]))
    }

    func setFxParam(_ fxId: Int, param: String, value: Double) {
        guard let paramNum = Int(param) else { return }
        client?.send(OscMessage(address: OscAddresses.fxParam(fxId, paramNum), args: [.float(Float(value))]))
    }

    // MARK: - Channel Detail Query

    @MainActor
    func queryChannelDetail(_ channelId: Int) {
        guard let client else { return }
        let osc = OscAddresses.self
        client.send(OscMessage(address: osc.eqOn(channelId)))
        for band in 1...4 {
            for addr in [osc.eqBandType, osc.eqBandFreq, osc.eqBandGain, osc.eqBandQ] {
                client.send(OscMessage(address: addr(channelId, band)))
            }
        }
        for addr in [osc.lowCutOn, osc.lowCutFreq, osc.lowCutSlope] {
            client.send(OscMessage(address: addr(channelId)))
        }
        for addr in [osc.compOn, osc.compThreshold, osc.compRatio, osc.compKnee,
                     osc.compMakeupGain, osc.compAttack, osc.compHold, osc.compRelease] {
            client.send(OscMessage(address: addr(channelId)))
        }
        // 查询 Bus Send
        queryBusSends(channelId)
    }

    // MARK: - EQ Send

    func setEqOn(_ channelId: Int, on: Bool) {
        client?.send(OscMessage(address: OscAddresses.eqOn(channelId), args: [.int(on ? 1 : 0)]))
    }

    func setEqBand(_ channelId: Int, band: Int, field: String, value: Double) {
        let addr: String
        switch field {
        case "type": addr = OscAddresses.eqBandType(channelId, band)
        case "freq": addr = OscAddresses.eqBandFreq(channelId, band)
        case "gain": addr = OscAddresses.eqBandGain(channelId, band)
        case "q":    addr = OscAddresses.eqBandQ(channelId, band)
        default: return
        }
        client?.send(OscMessage(address: addr, args: [.float(Float(value))]))
    }

    // MARK: - Low Cut Send

    func setLowCutOn(_ channelId: Int, on: Bool) {
        client?.send(OscMessage(address: OscAddresses.lowCutOn(channelId), args: [.int(on ? 1 : 0)]))
    }

    func setLowCutFreq(_ channelId: Int, freq: Double) {
        client?.send(OscMessage(address: OscAddresses.lowCutFreq(channelId), args: [.float(Float(freq))]))
    }

    func setLowCutSlope(_ channelId: Int, slope: Int) {
        client?.send(OscMessage(address: OscAddresses.lowCutSlope(channelId), args: [.int(Int32(slope))]))
    }

    // MARK: - Compressor Send

    func setCompOn(_ channelId: Int, on: Bool) {
        client?.send(OscMessage(address: OscAddresses.compOn(channelId), args: [.int(on ? 1 : 0)]))
    }

    func setCompParam(_ channelId: Int, param: String, value: Double) {
        let addr: String
        switch param {
        case "threshold":   addr = OscAddresses.compThreshold(channelId)
        case "ratio":       addr = OscAddresses.compRatio(channelId)
        case "knee":        addr = OscAddresses.compKnee(channelId)
        case "makeupGain":  addr = OscAddresses.compMakeupGain(channelId)
        case "attack":      addr = OscAddresses.compAttack(channelId)
        case "hold":        addr = OscAddresses.compHold(channelId)
        case "release":     addr = OscAddresses.compRelease(channelId)
        default: return
        }
        client?.send(OscMessage(address: addr, args: [.float(Float(value))]))
    }

    // MARK: - DCA Detail

    @MainActor
    func queryDcaDetail(_ dcaId: Int) {
        guard let client else { return }
        client.send(OscMessage(address: OscAddresses.dcaFader(dcaId)))
        client.send(OscMessage(address: OscAddresses.dcaMute(dcaId)))
        client.send(OscMessage(address: OscAddresses.dcaName(dcaId)))
        for ch in 1...32 {
            client.send(OscMessage(address: OscAddresses.channelDca(ch)))
        }
    }

    @MainActor
    func setChannelDcaMask(_ channelId: Int, mask: Int) {
        guard let index = channels.firstIndex(where: { $0.id == channelId }) else { return }
        channels[index].dcaMask = mask
        client?.send(OscMessage(address: OscAddresses.channelDca(channelId), args: [.int(Int32(mask))]))
    }

    @MainActor
    func toggleChannelDcaMembership(_ channelId: Int, dcaId: Int) {
        let bit = 1 << (dcaId - 1)
        let currentMask = channels.first(where: { $0.id == channelId })?.dcaMask ?? 0
        let newMask = (currentMask & bit) != 0 ? currentMask & ~bit : currentMask | bit
        setChannelDcaMask(channelId, mask: newMask)
    }

    // MARK: - Show（时间轴调度器）

    /// 启动卡片（若已有卡片在跑会先停掉；卡片可带 next 自动接续）
    @MainActor
    func runShowCard(_ card: TimelineCard) {
        guard let engine = showEngine else {
            errorMessage = "请先连接调音台"
            return
        }
        engine.run(cardId: card.id)
    }

    @MainActor
    func stopShow() {
        showEngine?.stopAll()
        cardProgress = EngineProgress()
    }

    @MainActor
    func addShowCard(name: String) {
        let card = TimelineCard(id: UUID().uuidString, name: name, desc: "新建卡片",
                                actions: [CardAction.new(kind: "fade_ch")])
        showCards.append(card)
        persistCards()
    }

    @MainActor
    func deleteShowCard(_ card: TimelineCard) {
        showCards.removeAll { $0.id == card.id }
        // 清掉指向它的 next，避免卡片链接到空处
        for i in 0..<showCards.count {
            if showCards[i].next == card.id { showCards[i].next = nil }
        }
        persistCards()
    }

    @MainActor
    func updateShowCard(_ card: TimelineCard) {
        guard let index = showCards.firstIndex(where: { $0.id == card.id }) else { return }
        showCards[index] = card
        persistCards()
    }

    @MainActor
    func togglePin(_ card: TimelineCard) {
        guard let index = showCards.firstIndex(where: { $0.id == card.id }) else { return }
        showCards[index].pinned.toggle()
        persistCards()
    }

    /// 卡片库变更后同步给引擎（未连接时引擎不存在，只落盘）
    @MainActor
    private func persistCards() {
        Self.saveShowCards(showCards)
        showEngine?.setCards(showCards)
    }

    // MARK: - Persistence

    private static let showsKey = "saved_show_cards_v2"
    private static let mixerIPKey = "mixer_ip"
    private static let mixerPortKey = "mixer_port"
    private static let bridgeEnabledKey = "bridge_enabled"

    private static func saveShowCards(_ cards: [TimelineCard]) {
        guard let data = try? JSONEncoder().encode(cards) else { return }
        UserDefaults.standard.set(data, forKey: showsKey)
    }

    /// 读取卡片库。旧版卡片格式（键 `saved_show_cards`，模型与服务端 v1 对齐）
    /// 无法解码时直接回落到出厂卡片，不做自动迁移
    /// （两代格式差异太大，静默转换容易产生错误动作）。
    private static func loadShowCards() -> [TimelineCard] {
        guard let data = UserDefaults.standard.data(forKey: showsKey),
              let cards = try? JSONDecoder().decode([TimelineCard].self, from: data),
              !cards.isEmpty else {
            return TimelineCard.defaults()
        }
        return cards
    }
}

// MARK: - UI State Models

struct ChannelUI: Identifiable {
    let id: Int
    var label: String
    var level: Float
    var isMuted: Bool
    var eq: EqState?
    var lowCut: LowCutState?
    var comp: CompState?
    var dcaMask: Int?
    var meterLevel: Float = 0
}

struct DcaUI: Identifiable {
    let id: Int
    var label: String
    var level: Float
    var isMuted: Bool
}

struct BusUI: Identifiable {
    let id: Int
    var label: String
    var level: Float
    var isMuted: Bool
}

struct FxUI: Identifiable {
    let id: Int
    var label: String
    var level: Float
    var isMuted: Bool
    var params: [String: Double]
}

struct ShowState: Identifiable {
    let id: Int
    var name: String
    var isActive: Bool
}
