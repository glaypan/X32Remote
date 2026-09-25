import SwiftUI
import X32RemoteCore

/// 卡片编辑器：与服务端 / 网页端使用同一套动作格式
/// （12 种白名单动作 + `at` 并行偏移 + `next` 接续 + `rel_db` 相对 dB）
struct ShowDetailView: View {
    @Environment(AppModel.self) private var appModel
    let cardId: String
    @State private var editingCard: TimelineCard
    @State private var hasChanges = false
    @State private var editingDraft: ActionDraft?

    init(card: TimelineCard) {
        self.cardId = card.id
        self._editingCard = State(initialValue: card)
    }

    var body: some View {
        Form {
            infoSection
            timelineSection
            actionsSection
        }
        .navigationTitle(editingCard.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") {
                    appModel.updateShowCard(editingCard)
                    hasChanges = false
                }
                .fontWeight(.semibold)
                .disabled(!hasChanges)
            }
        }
        .onChange(of: editingCard) { _, _ in hasChanges = true }
        .sheet(item: $editingDraft) { draft in
            NavigationStack {
                ActionEditorView(action: draft.action,
                                 channelName: channelName,
                                 busName: busName) { updated in
                    if editingCard.actions.indices.contains(draft.index) {
                        editingCard.actions[draft.index] = updated
                    }
                    editingDraft = nil
                }
            }
        }
    }

    // MARK: - 基本信息

    private var infoSection: some View {
        Section("基本信息") {
            HStack {
                Label("名称", systemImage: "tag")
                TextField("卡片名称", text: $editingCard.name)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Label("描述", systemImage: "note.text")
                TextField("可选描述", text: Binding(
                    get: { editingCard.desc },
                    set: { editingCard.desc = $0 }
                ))
                .multilineTextAlignment(.trailing)
            }
            Toggle(isOn: $editingCard.pinned) {
                Label("置顶", systemImage: "pin")
            }
            nextCardPicker
        }
    }

    /// 链式接续：本卡片跑完自动启动下一张
    private var nextCardPicker: some View {
        Picker(selection: Binding(
            get: { editingCard.next ?? "" },
            set: { editingCard.next = $0.isEmpty ? nil : $0 }
        )) {
            Text("不接续").tag("")
            ForEach(appModel.showCards.filter { $0.id != cardId }) { card in
                Text(card.name).tag(card.id)
            }
        } label: {
            Label("接续下一张", systemImage: "arrow.right.circle")
        }
    }

    // MARK: - 时间轴预览

    /// Swift 的元组不支持 keyPath，因此时间轴行用结构体承载
    private struct TimelineRow: Identifiable {
        let id: Int
        let start: Float
        let duration: Float
        let action: CardAction
        var number: Int { id + 1 }
    }

    private var timelineRows: [TimelineRow] {
        var cursor: Float = 0
        var out: [TimelineRow] = []
        for (i, a) in editingCard.actions.enumerated() {
            let start = a.isParallel ? a.at : cursor
            let dur = a.occupiesSeconds
            out.append(TimelineRow(id: i, start: start, duration: dur, action: a))
            cursor = start + dur
        }
        return out
    }

    private var timelineSection: some View {
        Section {
            HStack {
                Label("总时长", systemImage: "clock")
                Spacer()
                Text(String(format: "%.1f 秒", editingCard.totalSeconds))
                    .foregroundColor(.secondary)
            }
            HStack {
                Label("动作数", systemImage: "list.bullet")
                Spacer()
                Text("\(editingCard.actions.count) 个")
                    .foregroundColor(.secondary)
            }
            if editingCard.hasParallelActions {
                Label("含并行时间轴（at 偏移）", systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } header: {
            Text("时间轴")
        } footer: {
            Text("有 at 偏移的动作会与其它动作并行；未设 at 的动作依次排队。")
        }
    }

    // MARK: - 动作列表

    private var actionsSection: some View {
        Section {
            if editingCard.actions.isEmpty {
                emptyActionsRow
            } else {
                ForEach(timelineRows) { row in
                    Button {
                        editingDraft = ActionDraft(index: row.id, action: row.action)
                    } label: {
                        actionRow(row)
                    }
                    .foregroundColor(.primary)
                }
                .onDelete { indices in
                    editingCard.actions.remove(atOffsets: indices)
                }
            }
            addActionMenu
        } header: {
            Text("动作（按时间轴执行）")
        } footer: {
            if !editingCard.actions.isEmpty {
                Text("点击动作可修改参数，左滑删除。")
            }
        }
    }

    private var emptyActionsRow: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.title2).foregroundColor(.secondary)
                Text("暂无动作").font(.caption).foregroundColor(.secondary)
            }
            .padding()
            Spacer()
        }
    }

    private var addActionMenu: some View {
        Menu {
            Button { add("mute") } label: { Label("静音通道…", systemImage: "mic.slash") }
            Button { add("mute_bus") } label: { Label("静音 Bus…", systemImage: "speaker.slash") }
            Button { add("scene") } label: { Label("切换场景…", systemImage: "square.3.layers.3d") }
            Button { add("unmute_all") } label: { Label("全部取消静音", systemImage: "speaker.wave.2") }
            Divider()
            Button { add("fade_ch") } label: { Label("通道渐变…", systemImage: "slider.horizontal.3") }
            Button { add("fade_bus") } label: { Label("Bus 渐变…", systemImage: "arrowshape.turn.up.right") }
            Button { add("fade_all") } label: { Label("全体推子渐变…", systemImage: "slider.horizontal.below.rectangle") }
            Button { add("fade_odd_even") } label: { Label("奇偶过渡…", systemImage: "arrow.left.arrow.right") }
            Button { add("fade_from") } label: { Label("通道指定起点渐变…", systemImage: "slider.horizontal.3") }
            Button { add("fade_from_bus") } label: { Label("Bus 指定起点渐变…", systemImage: "arrowshape.turn.up.right") }
            Button { add("rel_db") } label: { Label("相对 ±dB…", systemImage: "plusminus.circle") }
            Divider()
            Button { add("wait") } label: { Label("等待…", systemImage: "timer") }
        } label: {
            Label("添加动作", systemImage: "plus.circle")
        }
    }

    private func add(_ kind: String) {
        editingCard.actions.append(CardAction.new(kind: kind))
    }

    @ViewBuilder
    private func actionRow(_ row: TimelineRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 2) {
                Text("\(row.number)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundColor(.secondary)
                Text(String(format: "%.1fs", row.start))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(row.action.isParallel ? Color.orange : Color.secondary)
            }
            .frame(width: 34, alignment: .leading)

            Image(systemName: row.action.icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.action.shortName)
                    .font(.subheadline)
                Text(actionDescription(row.action))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if row.duration > 0 {
                Text(String(format: "%.1fs", row.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 名称

    private func actionDescription(_ a: CardAction) -> String {
        if a.kind == "fade_all" || a.kind == "unmute_all" {
            return a.label { kind, idx in fallbackLabel(kind: kind, idx: idx) }
        }
        return a.label { kind, idx in
            let group = MixerSpec.kindGroup(kind)
            if group == "ch" { return channelName(idx) }
            if group == "bus" { return busName(idx) }
            return fallbackLabel(kind: kind, idx: idx)
        }
    }

    private func fallbackLabel(kind: String, idx: Int) -> String {
        "\(MixerSpec.label(of: MixerSpec.kindGroup(kind))) \(idx)"
    }

    private func channelName(_ idx: Int) -> String {
        if idx == AppModel.mainChannelId { return "Main LR" }
        let n = appModel.channels.first(where: { $0.id == idx })?.label
        return (n?.isEmpty == false ? n! : "Ch \(idx)")
    }

    private func busName(_ idx: Int) -> String {
        let n = appModel.buses.first(where: { $0.id == idx })?.label
        return (n?.isEmpty == false ? n! : "Bus \(idx)")
    }
}

// MARK: - 编辑草稿

private struct ActionDraft: Identifiable {
    let id = UUID()
    let index: Int
    let action: CardAction
}

// MARK: - 动作参数编辑器

private struct ActionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var action: CardAction
    private let channelName: (Int) -> String
    private let busName: (Int) -> String
    private let onSave: (CardAction) -> Void

    init(action: CardAction,
         channelName: @escaping (Int) -> String,
         busName: @escaping (Int) -> String,
         onSave: @escaping (CardAction) -> Void) {
        self._action = State(initialValue: action)
        self.channelName = channelName
        self.busName = busName
        self.onSave = onSave
    }

    var body: some View {
        Form {
            headerSection
            targetSection
            parameterSection
            if action.isFade {
                curveSection
            }
            timingSection
        }
        .navigationTitle(action.shortName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    onSave(action)
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
    }

    // MARK: 概要

    private var headerSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: action.icon).foregroundColor(.accentColor)
                Text(action.label { k, i in displayLabel(kind: k, idx: i) })
                    .font(.subheadline)
            }
        }
    }

    // MARK: 目标

    @ViewBuilder
    private var targetSection: some View {
        switch action.kind {
        case "mute":
            MultiTargetPicker(title: "选择通道", range: 1...32,
                              selection: $action.chs, label: channelName)
        case "mute_bus":
            MultiTargetPicker(title: "选择 Bus", range: 1...16,
                              selection: $action.buses, label: busName)
        case "fade_ch":
            MultiTargetPicker(title: "选择通道", range: 1...32,
                              selection: $action.chs, label: channelName)
        case "fade_bus":
            MultiTargetPicker(title: "选择 Bus", range: 1...16,
                              selection: $action.buses, label: busName)
        case "fade_from":
            SingleTargetPicker(title: "通道", range: 1...32,
                               value: $action.singleCh, label: channelName)
        case "fade_from_bus":
            SingleTargetPicker(title: "Bus", range: 1...16,
                               value: $action.singleBus, label: busName)
        case "rel_db":
            relDbSection
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var relDbSection: some View {
        Section("分组") {
            Picker("分组", selection: $action.group) {
                Text("通道").tag("ch")
                Text("Bus").tag("bus")
                Text("DCA").tag("dca")
            }
            .pickerStyle(.segmented)
        }
        switch action.group {
        case "bus":
            MultiTargetPicker(title: "选择 Bus", range: 1...16,
                              selection: $action.buses, label: busName)
        case "dca":
            MultiTargetPicker(title: "选择 DCA", range: 1...8,
                              selection: $action.dcas, label: dcaName)
        default:
            MultiTargetPicker(title: "选择通道", range: 1...32,
                              selection: $action.chs, label: channelName)
        }
    }

    // MARK: 参数

    @ViewBuilder
    private var parameterSection: some View {
        switch action.kind {
        case "scene":
            Section("场景") {
                Stepper(value: $action.scene, in: 1...99) {
                    HStack {
                        Text("场景号")
                        Spacer()
                        Text("\(action.scene)").foregroundColor(.secondary)
                    }
                }
            }
        case "wait":
            Section("等待") {
                percentRow("时长", value: $action.duration, range: 0.5...60, suffix: "秒", isPercent: false)
            }
        case "fade_all":
            Section("目标值") {
                percentRow("推到", value: $action.to, range: 0...1, suffix: "%", isPercent: true)
            }
        case "fade_odd_even":
            Section("目标值") {
                percentRow("奇数通道", value: $action.oddTo, range: 0...1, suffix: "%", isPercent: true)
                percentRow("偶数通道", value: $action.evenTo, range: 0...1, suffix: "%", isPercent: true)
            }
        case "fade_ch", "fade_bus":
            Section("目标值") {
                percentRow("推到", value: $action.to, range: 0...1, suffix: "%", isPercent: true)
            }
        case "fade_from", "fade_from_bus":
            Section("目标值") {
                percentRow("起始", value: $action.frm, range: 0...1, suffix: "%", isPercent: true)
                percentRow("推到", value: $action.to, range: 0...1, suffix: "%", isPercent: true)
            }
        case "rel_db":
            Section("增减量") {
                HStack {
                    Text("ΔdB")
                    Slider(value: $action.deltaDb, in: -30...30, step: 0.5)
                    Text(String(format: "%+.1f", action.deltaDb))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
        default:
            EmptyView()
        }
    }

    /// 百分比 / 绝对值的滑杆行
    private func percentRow(_ title: String,
                            value: Binding<Float>,
                            range: ClosedRange<Float>,
                            suffix: String,
                            isPercent: Bool) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: isPercent ? 0.01 : 0.5)
            Text(isPercent
                 ? "\(Int(value.wrappedValue * 100))\(suffix)"
                 : String(format: "%.0f%@", value.wrappedValue, suffix))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    // MARK: 曲线

    private var curveSection: some View {
        Section("渐变曲线") {
            Picker("曲线", selection: $action.curve) {
                ForEach(MixerSpec.curves, id: \.self) { c in
                    Text(MixerSpec.curveLabel(c)).tag(c)
                }
            }
        }
    }

    // MARK: 时间

    private var timingSection: some View {
        Section {
            if action.isFade || action.kind == "wait" {
                percentRow("时长", value: $action.duration,
                           range: action.kind == "wait" ? 0.5...60 : 0.5...30,
                           suffix: "秒", isPercent: false)
            }
            Toggle(isOn: Binding(
                get: { action.isParallel },
                set: { action.at = $0 ? 0 : -1 }
            )) {
                Text("并行（指定时间轴起点）")
            }
            if action.isParallel {
                percentRow("起点", value: $action.at, range: 0...600, suffix: "秒", isPercent: false)
            }
        } header: {
            Text("时间轴")
        } footer: {
            if action.isParallel {
                Text("该动作在卡片开始后 \(String(format: "%.1f", action.at)) 秒触发，与其它动作并行。")
            } else {
                Text("不设并行时，该动作接在上一个动作结束后执行。")
            }
        }
    }

    // MARK: 名称

    private func displayLabel(kind: String, idx: Int) -> String {
        let group = MixerSpec.kindGroup(kind)
        if group == "ch" { return channelName(idx) }
        if group == "bus" { return busName(idx) }
        return dcaName(idx)
    }

    private func dcaName(_ idx: Int) -> String {
        "DCA \(idx)"
    }
}

// MARK: - 目标选择器

private struct MultiTargetPicker: View {
    let title: String
    let range: ClosedRange<Int>
    @Binding var selection: [Int]
    let label: (Int) -> String

    private let columns = [GridItem(.adaptive(minimum: 52), spacing: 6)]

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(range), id: \.self) { i in
                    chip(i)
                }
            }
            .padding(.vertical, 4)

            if !selection.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Button(selection.count == range.count ? "清空" : "全选") {
                    selection = selection.count == range.count ? [] : Array(range)
                }
                .font(.caption2)
            }
        }
    }

    private func chip(_ i: Int) -> some View {
        let on = selection.contains(i)
        return Button {
            if on {
                selection.removeAll { $0 == i }
            } else {
                selection.append(i)
                selection.sort()
            }
        } label: {
            Text(String(format: "%02d", i))
                .font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(on ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                .foregroundColor(on ? Color.accentColor : Color.primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        selection.map { label($0) }.joined(separator: "、")
    }
}

private struct SingleTargetPicker: View {
    let title: String
    let range: ClosedRange<Int>
    @Binding var value: Int
    let label: (Int) -> String

    var body: some View {
        Section {
            Stepper(value: $value, in: range) {
                HStack {
                    Text(label(value))
                    Spacer()
                    Text(String(format: "%02d", value)).foregroundColor(.secondary)
                }
            }
        } header: {
            Text(title)
        }
    }
}

#Preview {
    NavigationStack {
        ShowDetailView(card: TimelineCard.defaults()[0])
            .environment(AppModel())
    }
}
