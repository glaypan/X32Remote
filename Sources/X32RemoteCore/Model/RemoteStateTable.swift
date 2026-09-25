import Foundation

/// `RemoteState` 的**统一按 (kind, idx) 访问层**。
///
/// 桥接引擎需要以调用方（时间轴调度器、真实回读）的视角操作台面，
/// 而 `RemoteState` 内部是按分组字典存放的；这一层把两者对接起来，
/// 使 `RemoteState` 同时充当"本地虚拟台面"（协议规范第 10 节）。
extension RemoteState {

    /// 分组 → 状态键前缀
    private static func keyPrefix(for group: String) -> String? {
        switch group {
        case "ch":    return "ch"
        case "bus":   return "bus"
        case "dca":   return "dca"
        case "auxin": return "auxin"
        case "usb":   return "usb"
        case "fxret": return "fxret"
        case "mtx":   return "mtx"
        case "main":  return nil      // main 只有一路，键固定
        default:      return nil
        }
    }

    private static func makeKey(group: String, idx: Int) -> String {
        if group == "main" { return "main/st" }
        return String(format: "%@/%02d", group, idx)
    }

    /// 键查找（容忍非补零写法，真机个别固件回包可能是不补零的）
    private func lookup<T>(_ dict: [String: T], group: String, idx: Int) -> T? {
        if let v = dict[RemoteState.makeKey(group: group, idx: idx)] { return v }
        if group != "main", let v = dict["\(group)/\(idx)"] { return v }
        return nil
    }

    // MARK: - 推子

    /// 读取推子行程（0..1）。`kind` 形如 `ch_fader` / `main_fader`
    public func fader(kind: String, idx: Int) -> Float {
        let group = MixerSpec.kindGroup(kind)
        switch group {
        case "ch":    return Float(lookup(channels, group: "ch", idx: idx)?.fader ?? 0)
        case "bus":   return Float(lookup(buses, group: "bus", idx: idx)?.fader ?? 0)
        case "dca":   return Float(lookup(dcas, group: "dca", idx: idx)?.fader ?? 0)
        case "auxin": return Float(lookup(auxins, group: "auxin", idx: idx)?.fader ?? 0)
        case "usb":   return Float(lookup(usbs, group: "usb", idx: idx)?.fader ?? 0)
        case "fxret": return Float(lookup(fxRets, group: "fxret", idx: idx)?.fader ?? 0)
        case "mtx":   return Float(lookup(mtxs, group: "mtx", idx: idx)?.fader ?? 0)
        case "main":  return Float(channels["main/st"]?.fader ?? 0)
        default:      return 0
        }
    }

    /// 写入推子行程（自动钳制到 0..1）
    public mutating func setFader(kind: String, idx: Int, to value: Float) {
        let v = Double(min(max(value, 0), 1))
        let group = MixerSpec.kindGroup(kind)
        let key = RemoteState.makeKey(group: group, idx: idx)
        switch group {
        case "ch":
            var s = lookup(channels, group: "ch", idx: idx) ?? ChannelState()
            s.fader = v
            channels[key] = s
        case "bus":
            var s = lookup(buses, group: "bus", idx: idx) ?? BusState(index: idx)
            s.fader = v
            buses[key] = s
        case "dca":
            var s = lookup(dcas, group: "dca", idx: idx) ?? DcaState(index: idx)
            s.fader = v
            dcas[key] = s
        case "auxin":
            var s = lookup(auxins, group: "auxin", idx: idx) ?? AuxState(index: idx)
            s.fader = v
            auxins[key] = s
        case "usb":
            var s = lookup(usbs, group: "usb", idx: idx) ?? AuxState(index: idx)
            s.fader = v
            usbs[key] = s
        case "fxret":
            var s = lookup(fxRets, group: "fxret", idx: idx) ?? AuxState(index: idx)
            s.fader = v
            fxRets[key] = s
        case "mtx":
            var s = lookup(mtxs, group: "mtx", idx: idx) ?? AuxState(index: idx)
            s.fader = v
            mtxs[key] = s
        case "main":
            var s = channels["main/st"] ?? ChannelState()
            s.fader = v
            channels["main/st"] = s
        default:
            break
        }
    }

    // MARK: - 静音（true = 开启）

    /// 读取开启状态。`kind` 形如 `ch_on` / `main_on`
    public func isOn(kind: String, idx: Int) -> Bool {
        let group = MixerSpec.kindGroup(kind)
        switch group {
        case "ch":    return !(lookup(channels, group: "ch", idx: idx)?.mute ?? true)
        case "bus":   return !(lookup(buses, group: "bus", idx: idx)?.mute ?? true)
        case "dca":   return !(lookup(dcas, group: "dca", idx: idx)?.mute ?? true)
        case "auxin": return !(lookup(auxins, group: "auxin", idx: idx)?.mute ?? true)
        case "usb":   return !(lookup(usbs, group: "usb", idx: idx)?.mute ?? true)
        case "fxret": return !(lookup(fxRets, group: "fxret", idx: idx)?.mute ?? true)
        case "mtx":   return !(lookup(mtxs, group: "mtx", idx: idx)?.mute ?? true)
        case "main":  return !(channels["main/st"]?.mute ?? true)
        default:      return true
        }
    }

    /// 写入开启状态
    public mutating func setOn(kind: String, idx: Int, to on: Bool) {
        let group = MixerSpec.kindGroup(kind)
        let key = RemoteState.makeKey(group: group, idx: idx)
        switch group {
        case "ch":
            var s = lookup(channels, group: "ch", idx: idx) ?? ChannelState()
            s.mute = !on
            channels[key] = s
        case "bus":
            var s = lookup(buses, group: "bus", idx: idx) ?? BusState(index: idx)
            s.mute = !on
            buses[key] = s
        case "dca":
            var s = lookup(dcas, group: "dca", idx: idx) ?? DcaState(index: idx)
            s.mute = !on
            dcas[key] = s
        case "auxin":
            var s = lookup(auxins, group: "auxin", idx: idx) ?? AuxState(index: idx)
            s.mute = !on
            auxins[key] = s
        case "usb":
            var s = lookup(usbs, group: "usb", idx: idx) ?? AuxState(index: idx)
            s.mute = !on
            usbs[key] = s
        case "fxret":
            var s = lookup(fxRets, group: "fxret", idx: idx) ?? AuxState(index: idx)
            s.mute = !on
            fxRets[key] = s
        case "mtx":
            var s = lookup(mtxs, group: "mtx", idx: idx) ?? AuxState(index: idx)
            s.mute = !on
            mtxs[key] = s
        case "main":
            var s = channels["main/st"] ?? ChannelState()
            s.mute = !on
            channels["main/st"] = s
        default:
            break
        }
    }

    // MARK: - DCA 成员位掩码（bit0 = DCA1）

    public func dcaMask(ofChannel idx: Int) -> Int {
        lookup(channels, group: "ch", idx: idx)?.dcaMask ?? 0
    }

    public mutating func setDcaMask(ofChannel idx: Int, to mask: Int) {
        let key = RemoteState.makeKey(group: "ch", idx: idx)
        var s = lookup(channels, group: "ch", idx: idx) ?? ChannelState()
        s.dcaMask = mask & 0xFF
        channels[key] = s
    }

    /// 某个 DCA 的成员通道号（升序）
    public func dcaMembers(_ dcaIdx: Int) -> [Int] {
        let bit = 1 << (max(dcaIdx, 1) - 1)
        return channels.compactMap { key, ch in
            guard key.hasPrefix("ch/") || key.hasPrefix("ch") else { return nil }
            guard let mask = ch.dcaMask, mask & bit != 0 else { return nil }
            return Int(key.split(separator: "/").last ?? "")
        }.sorted()
    }

    // MARK: - 名称

    /// 分组原名（真台 12 字符限制）
    public func x32Name(group: String, idx: Int) -> String? {
        switch group {
        case "ch":    return lookup(channels, group: "ch", idx: idx)?.x32Name
        case "bus":   return lookup(buses, group: "bus", idx: idx)?.x32Name
        case "dca":   return lookup(dcas, group: "dca", idx: idx)?.x32Name
        case "auxin": return lookup(auxins, group: "auxin", idx: idx)?.x32Name
        case "usb":   return lookup(usbs, group: "usb", idx: idx)?.x32Name
        case "fxret": return lookup(fxRets, group: "fxret", idx: idx)?.x32Name
        case "mtx":   return lookup(mtxs, group: "mtx", idx: idx)?.x32Name
        case "main":  return channels["main/st"]?.x32Name
        default:      return nil
        }
    }

    /// 显示名：本地别名优先，其次真台原名，最后 `分组+编号`
    public func displayName(kind: String, idx: Int) -> String {
        let group = MixerSpec.kindGroup(kind)
        let alias: String?
        switch group {
        case "ch":    alias = lookup(channels, group: "ch", idx: idx)?.label
        case "bus":   alias = lookup(buses, group: "bus", idx: idx)?.label
        case "dca":   alias = lookup(dcas, group: "dca", idx: idx)?.label
        case "auxin": alias = lookup(auxins, group: "auxin", idx: idx)?.label
        case "usb":   alias = lookup(usbs, group: "usb", idx: idx)?.label
        case "fxret": alias = lookup(fxRets, group: "fxret", idx: idx)?.label
        case "mtx":   alias = lookup(mtxs, group: "mtx", idx: idx)?.label
        case "main":  alias = channels["main/st"]?.label
        default:      alias = nil
        }

        if let alias, !alias.isEmpty { return alias }
        if let n = x32Name(group: group, idx: idx), !n.isEmpty { return n }

        let gl = MixerSpec.label(of: group)
        return group == "main" ? gl : String(format: "%@ %02d", gl, idx)
    }

    /// 带分组后缀的完整标签，用于冲突告警文案（与网页端一致）
    public func targetLabel(kind: String, idx: Int) -> String {
        let group = MixerSpec.kindGroup(kind)
        let n = x32Name(group: group, idx: idx) ?? ""
        let gl = MixerSpec.label(of: group)
        if group == "main" { return n.isEmpty ? gl : "\(n)(\(gl))" }
        let num = String(format: "%02d", idx)
        return n.isEmpty ? "\(gl) \(num)" : "\(n)(\(gl)\(num))"
    }
}
