import Foundation
import SwiftUI
import X32RemoteCore

/// 详情页的页签（用结构体而不是元组：Swift 的 KeyPath 不支持 `\.0` 这种元组下标，
/// `ForEach(tabs, id: \.0)` 会直接编译失败）
struct ChannelTab: Identifiable {
    let id: String
    let label: String
}

/// 通道详情：**按台面能力**渲染处理参数（均衡 / 噪声门 / 压缩 / 插入 / 增益 / 声像 / 发送）。
///
/// 不是给某个组写死的页面：控件全部由 `ParamTable`（随包内嵌的参数登记表）生成，
/// 服务端加一个参数，这里立刻出现，不用改 Swift。各组能力不同（Bus 是 6 段 EQ、
/// FX 返回只有声像和发送、Matrix 没有声像），页签按 `ParamGroupCaps` 自动取舍。
struct ChannelDetailView: View {
    @Environment(AppModel.self) private var appModel

    let group: String
    let idx: Int

    /// 兼容旧调用（通道页仍然只传通道号，默认就是 ch 组）
    init(channelId: Int, group: String = "ch", idx: Int? = nil) {
        self.group = group
        self.idx = idx ?? channelId
    }

    @State private var tab = "pre"

    private var caps: ParamGroupCaps? { ParamTable.caps(group) }
    private var rows: [ParamRow] { ParamTable.rows(group) }

    /// 实际显示的页签（按能力）
    private var tabs: [ChannelTab] {
        guard let c = caps else { return [] }
        var out: [ChannelTab] = []
        if c.hasPre || c.hasIns || c.hasPan { out.append(ChannelTab(id: "pre", label: "前置")) }
        if c.hasGate { out.append(ChannelTab(id: "gate", label: "门")) }
        if c.hasDyn { out.append(ChannelTab(id: "dyn", label: "动态")) }
        if c.eq > 0 { out.append(ChannelTab(id: "eq", label: "均衡")) }
        if c.hasSend { out.append(ChannelTab(id: "send", label: "发送")) }
        return out
    }

    private var title: String {
        if group == "main" { return caps?.label ?? "Main" }
        return ParamTable.itemLabel(group, idx: idx)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if tab == "send" {
                        sendSection
                    } else {
                        paramSection
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            appModel.queryParams(group: group, idx: idx)
            if !tabs.contains(where: { $0.id == tab }), let first = tabs.first {
                tab = first.id
            }
        }
    }

    // MARK: - 头（推子 + 静音）

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.title3).bold()
                Spacer()
                Text(muted ? "MUTED" : String(format: "%.0f%%", level * 100))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(muted ? .red : .secondary)
            }
            HStack(spacing: 10) {
                Slider(value: Binding(get: { Double(level) },
                                      set: { appModel.setFader(group: group, idx: idx, level: Float($0)) }),
                       in: 0...1)
                .tint(.blue)
                Button {
                    appModel.setMute(group: group, idx: idx, muted: !muted)
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(muted ? .red : .secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    private var level: Float { appModel.faderValue(group: group, idx: idx) }
    private var muted: Bool { appModel.isMutedValue(group: group, idx: idx) }

    // MARK: - 页签条

    // 页签条 + 分隔线。两个视图必须包在容器里：
    // `some View` 计算属性只对**单个**表达式做隐式返回，直接写两句会报
    // "function declares an opaque return type, but has no return statements"。
    private var tabBar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { t in
                        Button {
                            tab = t.id
                        } label: {
                            Text(t.label)
                                .font(.subheadline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(tab == t.id ? Color.accentColor : Color(.secondarySystemFill))
                                .foregroundColor(tab == t.id ? .white : .primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            Divider()
        }
    }

    // MARK: - 处理参数

    private var filteredRows: [ParamRow] {
        rows.filter { $0.section == tab }
    }

    @ViewBuilder
    private var paramSection: some View {
        if filteredRows.isEmpty {
            Text("本通道类型没有这项处理")
                .font(.footnote).foregroundColor(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if tab == "eq" {
            // EQ 按段分组：4 段（ch/auxin）或 6 段（bus/mtx/main）
            ForEach(1...max(caps?.eq ?? 0, 1), id: \.self) { band in
                let bandRows = filteredRows.filter { $0.field.hasPrefix("eq\(band)_") }
                if !bandRows.isEmpty {
                    eqBandHeader(band)
                    ForEach(bandRows) { row in paramRow(row) }
                    Divider().padding(.vertical, 4)
                }
            }
        } else {
            ForEach(filteredRows) { row in paramRow(row) }
        }
    }

    private func eqBandHeader(_ band: Int) -> some View {
        // 真台没有"每段一个开关"的地址（只有整组 /eq/on），所以这里只做分段标题，
        // 总开关由 eq_on 那一行提供（它也在 eq 页签里）。
        Text("EQ \(band)")
            .font(.subheadline.bold())
            .padding(.horizontal).padding(.top, 6)
    }

    // MARK: - 单行控件

    @ViewBuilder
    private func paramRow(_ row: ParamRow) -> some View {
        let value = appModel.paramValue(group: group, idx: idx, row: row)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.label).font(.footnote).foregroundColor(.secondary)
                if row.unverified {
                    Text("⚠️").font(.caption2)
                }
                Spacer()
                Text(row.display(value)).font(.footnote.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            control(row, value: value)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func control(_ row: ParamRow, value: Double) -> some View {
        if row.isBool {
            Toggle("", isOn: Binding(
                get: { value != 0 },
                set: { appModel.setParam(group: group, idx: idx, row: row, value: $0 ? 1 : 0) }
            ))
            .labelsHidden()
            .tint(.blue)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let en = row.enumValues, en.count <= 6 {
            // 少量枚举 → 分段控件（EQ 类型 / 低切斜率 / 压缩比）
            Picker("", selection: Binding(
                get: { row.clamp(value) },
                set: { appModel.setParam(group: group, idx: idx, row: row, value: $0) }
            )) {
                ForEach(en, id: \.self) { v in Text(row.display(v)).tag(v) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else if row.logSteps > 1 || row.hi - row.lo > 200 {
            // 大跨度（频率 20–20000）走对数映射，否则低频挤在一起没法调
            logSlider(row, value: value)
        } else {
            Slider(value: Binding(
                get: { row.clamp(value) },
                set: { appModel.setParam(group: group, idx: idx, row: row, value: $0) }
            ), in: row.lo...max(row.hi, row.lo + 0.001))
            .tint(.blue)
        }
    }

    /// 对数滑杆：内部走 0..1 的位置，按 log 映射回真实值
    private func logSlider(_ row: ParamRow, value: Double) -> some View {
        let lo = max(row.lo, 1e-6)
        let hi = max(row.hi, lo * 1.001)
        let pos = log(max(min(value, hi), lo) / lo) / log(hi / lo)
        return Slider(value: Binding(
            get: { pos },
            set: { p in
                let v = lo * pow(hi / lo, min(max(p, 0), 1))
                appModel.setParam(group: group, idx: idx, row: row, value: v)
            }
        ), in: 0...1)
        .tint(.blue)
    }

    // MARK: - 发送

    private var sendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let c = caps, c.hasSend {
                Text("发送到 \(targetLabelPrefix) 1–\(c.send)")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(1...c.send, id: \.self) { bus in
                    sendRow(bus: bus, caps: c)
                    if bus < c.send { Divider() }
                }
            }
        }
        .padding(.horizontal)
    }

    /// 目标名：输入类送 Mix Bus，Bus/Main 送 Matrix
    private var targetLabelPrefix: String {
        (group == "bus" || group == "main") ? "Matrix" : "Bus"
    }

    private func sendRow(bus: Int, caps: ParamGroupCaps) -> some View {
        let level = appModel.sendValue(group: group, src: idx, bus: bus, field: "level") ?? 0
        let on = (appModel.sendValue(group: group, src: idx, bus: bus, field: "on") ?? 0) != 0
        let tap = Int(appModel.sendValue(group: group, src: idx, bus: bus, field: "tap") ?? 3)
        // 取点选项从登记表生成的发送行里取（不在 Swift 里手写枚举）
        let tapNames: [String] = {
            if let lb = ParamTable.sendRows(group: group).first(where: { $0.field == "tap" })?.labels,
               !lb.isEmpty { return lb }
            return ["<-EQ", "EQ->", "PRE", "POST", "GRP"]
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(format: "%@ %02d", targetLabelPrefix, bus))
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(on ? .primary : .secondary)
                Spacer()
                // 取点只有奇数目标定义（真台成对共享）——偶数目标不显示开关
                if caps.hasTap && bus % 2 == 1 {
                    Picker("", selection: Binding(
                        get: { tap },
                        set: { appModel.setSendParam(group: group, src: idx, bus: bus, field: "tap", value: Double($0)) }
                    )) {
                        ForEach(0..<tapNames.count, id: \.self) { i in
                            Text(tapNames[i]).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Button {
                    appModel.setSendParam(group: group, src: idx, bus: bus, field: "on", value: on ? 0 : 1)
                } label: {
                    Text("ON")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(on ? Color.blue : Color(.secondarySystemFill))
                        .foregroundColor(on ? .white : .secondary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Slider(value: Binding(
                get: { level },
                set: { appModel.setSendParam(group: group, src: idx, bus: bus, field: "level", value: $0) }
            ), in: 0...1)
            .tint(on ? .blue : .gray)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        ChannelDetailView(channelId: 1)
            .environment(AppModel())
    }
}
