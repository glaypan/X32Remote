import Foundation

/// X32/M32 默认 OSC 端口
public let defaultX32OscPort = 10023

/// X32/M32 OSC 地址生成器和 dB 转换工具
public enum OscAddresses {
    // MARK: - 静态地址
    
    /// Keepalive 地址 (每 9 秒发送一次以保持连接)
    public static let keepalive = "/xremote"

    /// 台面变更推送订阅地址
    ///
    /// 真机: `/subscribe` + Int 1 开启参数变化推送 (renewal),0 关闭。
    /// 订阅后台面上的推子/静音等操作会实时回传给 App。
    public static let subscribe = "/subscribe"
    
    // MARK: - 通道地址生成
    
    /// 生成通道推子地址
    public static func channelFader(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/fader", channel)
    }
    
    /// 生成通道静音地址
    public static func channelMute(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/on", channel)
    }
    
    /// 生成通道名称地址
    public static func channelName(_ channel: Int) -> String {
        return String(format: "/ch/%02d/config/name", channel)
    }
    
    /// 生成通道增益地址
    public static func channelGain(_ channel: Int) -> String {
        return String(format: "/ch/%02d/preamp/gain", channel)
    }

    /// 生成通道 Bus Send 电平地址
    public static func busSend(_ channel: Int, _ bus: Int) -> String {
        return String(format: "/ch/%02d/mix/%02d/level", channel, bus)
    }

    // MARK: - DCA 地址生成
    
    /// 生成 DCA 推子地址
    ///
    /// 注意: 与查询和状态键保持一致的两位补零格式 (/dca/01/fader),
    /// 否则会在 RemoteState 中产生重复条目。
    public static func dcaFader(_ dca: Int) -> String {
        return String(format: "/dca/%02d/fader", dca)
    }

    /// 生成 DCA 静音地址
    public static func dcaMute(_ dca: Int) -> String {
        return String(format: "/dca/%02d/on", dca)
    }
    
    /// 生成 DCA 名称地址
    public static func dcaName(_ dca: Int) -> String {
        return String(format: "/dca/%02d/config/name", dca)
    }
    
    /// 生成通道 DCA 成员分配地址 (bitmask, bit 0 = DCA 1)
    ///
    /// ⚠️ 以模拟器与《共享协议规范》第 3.3 节为准使用 `mix` 段
    /// （历史写法 `/ch/NN/grp/dca` 模拟器不认，会导致 DCA 成员读写静默失效；
    ///  解析端 `OscAddressParser` 对两种写法都兼容）。
    public static func channelDca(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/dca", channel)
    }
    
    // MARK: - EQ 地址生成
    
    /// 生成通道 EQ 开关地址
    public static func eqOn(_ channel: Int) -> String {
        return String(format: "/ch/%02d/eq/on", channel)
    }
    
    /// 生成通道 EQ 频段滤波器类型地址
    public static func eqBandType(_ channel: Int, _ band: Int) -> String {
        return String(format: "/ch/%02d/eq/band/%d/type", channel, band)
    }
    
    /// 生成通道 EQ 频段频率地址
    public static func eqBandFreq(_ channel: Int, _ band: Int) -> String {
        return String(format: "/ch/%02d/eq/band/%d/freq", channel, band)
    }
    
    /// 生成通道 EQ 频段增益地址
    public static func eqBandGain(_ channel: Int, _ band: Int) -> String {
        return String(format: "/ch/%02d/eq/band/%d/gain", channel, band)
    }
    
    /// 生成通道 EQ 频段 Q 值地址
    public static func eqBandQ(_ channel: Int, _ band: Int) -> String {
        return String(format: "/ch/%02d/eq/band/%d/q", channel, band)
    }
    
    // MARK: - Low Cut 地址生成
    
    /// 生成通道 Low Cut 开关地址
    public static func lowCutOn(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/lc/on", channel)
    }
    
    /// 生成通道 Low Cut 频率地址
    public static func lowCutFreq(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/lc/freq", channel)
    }
    
    /// 生成通道 Low Cut 斜率地址
    public static func lowCutSlope(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/lc/slope", channel)
    }
    
    // MARK: - Compressor 地址生成
    
    /// 生成通道压缩器开关地址
    public static func compOn(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/comp/on", channel)
    }
    
    /// 生成通道压缩器阈值地址
    public static func compThreshold(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/comp/threshold", channel)
    }
    
    /// 生成通道压缩器比率地址
    public static func compRatio(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/comp/ratio", channel)
    }
    
    /// 生成通道压缩器 Knee 地址
    public static func compKnee(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/comp/knee", channel)
    }
    
    /// 生成通道压缩器补偿增益地址
    public static func compMakeupGain(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/comp/makeup_gain", channel)
    }
    
    /// 生成通道压缩器启动时间地址
    public static func compAttack(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/comp/attack", channel)
    }
    
    /// 生成通道压缩器保持时间地址
    public static func compHold(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/comp/hold", channel)
    }
    
    /// 生成通道压缩器释放时间地址
    public static func compRelease(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/comp/release", channel)
    }
    
    // MARK: - 场景地址生成
    
    /// 生成场景调用地址
    public static func sceneRecall(_ scene: Int) -> String {
        return "/scene/\(scene)/load"
    }
    
    // MARK: - dB 转换

    /// 自动发现 /xinfo 地址
    public static let xinfo = "/xinfo"

    // MARK: - Bus 地址

    /// 生成通道 Bus Send 开关地址
    public static func busSendOn(_ channel: Int, _ bus: Int) -> String {
        return String(format: "/ch/%02d/mix/%02d/on", channel, bus)
    }

    /// 生成 Bus 名称地址
    public static func busName(_ bus: Int) -> String {
        return String(format: "/bus/%02d/config/name", bus)
    }

    /// 生成 Bus 主推子地址
    public static func busFader(_ bus: Int) -> String {
        return String(format: "/bus/%02d/mix/fader", bus)
    }

    /// 生成 Bus 静音地址
    public static func busMute(_ bus: Int) -> String {
        return String(format: "/bus/%02d/mix/on", bus)
    }

    // MARK: - FX 地址

    /// 生成 FX 名称地址
    public static func fxName(_ fx: Int) -> String {
        return String(format: "/fx/%d/config/name", fx)
    }

    /// 生成 FX 返回推子地址
    public static func fxFader(_ fx: Int) -> String {
        return String(format: "/rtn/fx/%d/mix/fader", fx)
    }

    /// 生成 FX 返回静音地址
    public static func fxMute(_ fx: Int) -> String {
        return String(format: "/rtn/fx/%d/mix/on", fx)
    }

    /// 生成 FX 参数地址
    public static func fxParam(_ fx: Int, _ param: Int) -> String {
        return String(format: "/fx/%d/par/%02d", fx, param)
    }

    // MARK: - 电平表

    /// 生成通道电平地址
    public static func channelLevel(_ channel: Int) -> String {
        return String(format: "/ch/%02d/mix/level", channel)
    }

    /// 通道电平表订阅地址 (/meters/1 返回包含 32 通道电平的二进制 blob)
    public static let metersChannels = "/meters/1"

    // MARK: - 主输出 (Main LR)

    /// 主输出推子地址
    public static let mainFader = "/main/st/mix/fader"

    /// 主输出静音地址
    public static let mainMute = "/main/st/mix/on"

    /// 主输出名称地址
    public static let mainName = "/main/st/config/name"

    /// 将 X32 电平表原始 dB 值转换为 UI 用 0.0-1.0 电平
    ///
    /// X32 /meters blob 中的值为 dB 浮点数,-32768 表示 -∞。
    /// 这里将 -60 dB ~ 0 dB 映射到 0 ~ 1 (超过 0 dB 削波,钳位到 1)。
    public static func meterToLevel(_ db: Float) -> Float {
        guard db > -32700 else { return 0 }
        return min(max((db + 60.0) / 60.0, 0), 1)
    }

    /// 将 /meters blob 解析为 Float 数组
    ///
    /// X32 /meters blob 格式: 前 4 字节为 Int32 数量 (大端序),
    /// 随后为对应数量的 Float 电平值 (大端序,单位 dB)。
    /// 本方法跳过数量字段,仅返回电平值数组。
    public static func meterFloats(from blob: Data) -> [Float] {
        // 至少要有 4 字节数量字段 + 1 个 Float
        guard blob.count >= 8 else { return [] }

        let count = Int(Int32(bigEndian: blob[blob.startIndex..<(blob.startIndex + 4)].withUnsafeBytes {
            $0.load(as: Int32.self)
        }))
        guard count > 0 else { return [] }

        let available = (blob.count - 4) / 4
        let n = min(count, available)
        var result: [Float] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            let start = blob.startIndex + 4 + i * 4
            let bits = blob[start..<(start + 4)].withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }
            result.append(Float(bitPattern: bits))
        }
        return result
    }

    // MARK: - dB 转换
    
    /// 将线性值 (0.0-1.0) 转换为 dB
    public static func linearToDb(_ linear: Double) -> Double {
        if linear <= 0.0 {
            return -Double.infinity
        }
        
        if linear >= 0.75 {
            // 0.75-1.0 映射到 0-10 dB (线性)
            return (linear - 0.75) / 0.25 * 10.0
        } else {
            // 0.0-0.75 映射到 -∞ 到 0 dB (对数)
            let normalized = linear / 0.75
            return 20.0 * log10(normalized)
        }
    }
    
    /// 将 dB 值转换为线性值 (0.0-1.0)
    public static func dbToLinear(_ db: Double) -> Double {
        if db.isInfinite && db < 0 {
            return 0.0
        }
        if db <= -90.0 {
            return 0.0
        }
        if db >= 10.0 {
            return 1.0
        }
        
        if db >= 0.0 {
            // 0-10 dB 映射到 0.75-1.0 (线性)
            return 0.75 + (db / 10.0) * 0.25
        } else {
            // -90 到 0 dB 映射到 0.0-0.75 (对数)
            let normalized = pow(10.0, db / 20.0)
            return normalized * 0.75
        }
    }
}
