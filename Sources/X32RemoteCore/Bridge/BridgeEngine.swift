import Foundation

/// 桥接事件（冲突告警、链路状态变化等），供 UI 显示。
public struct BridgeEvent: Identifiable, Equatable, Sendable {
    public let id: Int
    public let time: String
    public let text: String
    /// 是否为告警（UI 用红色呈现）
    public let isWarning: Bool

    public init(id: Int, time: String, text: String, isWarning: Bool) {
        self.id = id
        self.time = time
        self.text = text
        self.isWarning = isWarning
    }
}

/// 桥接引擎：让手机自己承担"服务端桥接"的角色。
///
/// 拓扑：
/// ```
/// [手机 UI / 卡片引擎] ──► 本地虚拟台面（RemoteState）
///                              │
///                              └──► OSC 转发 ──► 真台
///                              ◄── 回读同步 ──┘
/// ```
///
/// 三件事，与服务端 `x32_simulator.py` 的桥接模块逐项对齐：
///  1. **回声抑制**：自己刚转发出去的值会在 2 秒 / 0.02 容差窗口内被认出来，
///     只用于对齐本地，不会误判成"真台被人动了"
///  2. **回读同步**：真台面板上的变化会静默同步进本地虚拟台面
///  3. **手动干预检测**：真台上的变化若命中正在被卡片驱动的那一路，
///     会交给 `ShowEngine` 冻结该路并抛出告警事件
public final class BridgeEngine: @unchecked Sendable {

    /// 链路状态
    public enum State: Equatable, Sendable {
        /// 未启用桥接
        case off
        /// 已启用，但还没收到过真台回包
        case link
        /// 正常（近期有回包）
        case online
        /// 真台长期无回包（检查地址、网线、是否同网段）
        case stale

        public var label: String {
            switch self {
            case .off:    return "未启用"
            case .link:   return "已启用 · 等待真台回包"
            case .online: return "已连接"
            case .stale:  return "真台无回包"
            }
        }
    }

    /// 回读判定结果
    public enum Incoming: Equatable, Sendable {
        /// 自己刚写出去的回声，只需对齐本地
        case echo
        /// 真台端发生的变化（可能来自面板，也可能来自其它控制端）
        case remoteChange
    }

    private struct ForwardRecord {
        var value: Float
        var time: TimeInterval
    }

    /// 回声窗口：2 秒
    public static let echoWindow: TimeInterval = 2.0
    /// 回声容差：0.02
    public static let echoTolerance: Float = 0.02
    /// 超过这个时长没回包就判为 stale
    public static let staleAfter: TimeInterval = 20.0
    /// 事件环形缓冲长度
    public static let eventLimit = 20

    private let lock = NSLock()
    private var recent: [String: ForwardRecord] = [:]
    private var _state: State = .off
    private var _lastReceived: TimeInterval = 0
    private var _events: [BridgeEvent] = []
    private var eventSeq = 0

    /// 事件出口，回调在主线程
    public var onEvent: ((BridgeEvent) -> Void)?
    /// 状态变化出口，回调在主线程
    public var onStateChange: ((State) -> Void)?

    public init() {}

    // MARK: - 开关

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public var lastReceivedAt: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return _lastReceived
    }

    public var events: [BridgeEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    /// 启用/停用桥接。停用时清空回声记录（避免下次启用误抑制）。
    public func setEnabled(_ enabled: Bool) {
        lock.lock()
        recent.removeAll()
        _lastReceived = 0
        let next: State = enabled ? .link : .off
        let changed = next != _state
        _state = next
        lock.unlock()
        if changed { notifyState(next) }
    }

    public func clearEvents() {
        lock.lock()
        _events.removeAll()
        lock.unlock()
    }

    // MARK: - 回声抑制

    /// 登记一次转发（自己写出去的值）。只有桥接启用时才需要。
    public func noteForward(kind: String, idx: Int, value: Float) {
        let key = BridgeEngine.key(kind: kind, idx: idx)
        let now = Date().timeIntervalSince1970
        lock.lock()
        // 顺手清理过期记录，避免无限增长
        recent = recent.filter { now - $0.value.time < BridgeEngine.echoWindow }
        recent[key] = ForwardRecord(value: value, time: now)
        lock.unlock()
    }

    /// 判定一条真台回读是"自己的回声"还是"真台端的变化"
    public func classify(kind: String, idx: Int, value: Float) -> Incoming {
        let key = BridgeEngine.key(kind: kind, idx: idx)
        let now = Date().timeIntervalSince1970
        lock.lock()
        let rec = recent[key]
        lock.unlock()
        if let rec,
           now - rec.time < BridgeEngine.echoWindow,
           abs(rec.value - value) < BridgeEngine.echoTolerance {
            return .echo
        }
        return .remoteChange
    }

    // MARK: - 链路活动

    /// 收到真台回包（电平表 / xinfo 也会刷新在线状态）
    public func noteActivity() {
        let now = Date().timeIntervalSince1970
        lock.lock()
        _lastReceived = now
        let changed = _state != .online
        if changed { _state = .online }
        lock.unlock()
        if changed { notifyState(.online) }
    }

    /// 由定时器定期调用，检测"长期无回包"
    public func refreshStaleness() {
        lock.lock()
        guard _state != .off, _state != .stale else { lock.unlock(); return }
        let idle = Date().timeIntervalSince1970 - _lastReceived
        guard _lastReceived > 0, idle > BridgeEngine.staleAfter else { lock.unlock(); return }
        _state = .stale
        lock.unlock()
        pushEvent("真台无回包 — 请检查地址、网线与是否在同一网段", isWarning: true)
        notifyState(.stale)
    }

    // MARK: - 事件

    public func pushEvent(_ text: String, isWarning: Bool) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let event: BridgeEvent
        lock.lock()
        eventSeq += 1
        event = BridgeEvent(id: eventSeq, time: fmt.string(from: Date()),
                            text: text, isWarning: isWarning)
        _events.append(event)
        if _events.count > BridgeEngine.eventLimit {
            _events.removeFirst(_events.count - BridgeEngine.eventLimit)
        }
        lock.unlock()

        guard let sink = onEvent else { return }
        DispatchQueue.main.async { sink(event) }
    }

    private func notifyState(_ s: State) {
        guard let sink = onStateChange else { return }
        DispatchQueue.main.async { sink(s) }
    }

    private static func key(kind: String, idx: Int) -> String { "\(kind):\(idx)" }
}
