import SwiftUI
import X32RemoteCore

struct ShowDetailView: View {
    @Environment(AppModel.self) private var appModel
    let cardId: String
    @State private var editingCard: ShowCard
    @State private var hasChanges = false

    // 编辑会话
    @State private var editingAction: ShowAction?
    @State private var editingFadeDraft: FadeDraft?
    @State private var editingFadeIndex: Int?
    @State private var showAddFade = false

    init(card: ShowCard) {
        self.cardId = card.id
        self._editingCard = State(initialValue: card)
    }

    var body: some View {
        Form {
            infoSection
            actionsSection
            fadesSection
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
        .sheet(item: $editingAction) { action in
            NavigationStack {
                ActionEditorView(action: action) { updated in
                    if let idx = editingCard.actions.firstIndex(where: { $0.id == updated.id }) {
                        editingCard.actions[idx] = updated
                    }
                    editingAction = nil
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $editingFadeDraft) { draft in
            NavigationStack {
                FadeEditorView(draft: draft) { fade in
                    if let idx = editingFadeIndex, editingCard.fades.indices.contains(idx) {
                        editingCard.fades[idx] = fade
                    } else {
                        editingCard.fades.append(fade)
                    }
                    editingFadeDraft = nil
                    editingFadeIndex = nil
                }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showAddFade) {
            NavigationStack {
                FadeEditorView(draft: FadeDraft()) { fade in
                    editingCard.fades.append(fade)
                    showAddFade = false
                }
            }
            .presentationDetents([.large])
        }
    }

    // MARK: - Info

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
                    get: { editingCard.description ?? "" },
                    set: { editingCard.description = $0.isEmpty ? nil : $0 }
                ))
                .multilineTextAlignment(.trailing)
            }
            HStack {
                Label("动作", systemImage: "list.bullet")
                Spacer()
                Text("\(editingCard.actions.count) 个")
                    .foregroundColor(.secondary)
            }
            HStack {
                Label("推子渐变", systemImage: "slider.horizontal.below.square.filled.and.square")
                Spacer()
                Text("\(editingCard.fades.count) 条")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            if editingCard.actions.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.title2).foregroundColor(.secondary)
                        Text("暂无动作").font(.caption).foregroundColor(.secondary)
                    }
                    .padding()
                    Spacer()
                }
            } else {
                ForEach(editingCard.actions) { action in
                    Button { editingAction = action } label: { actionRow(action) }
                        .foregroundColor(.primary)
                }
                .onDelete { indices in
                    editingCard.actions.remove(atOffsets: indices)
                }
            }

            Menu {
                Button { addSceneRecall() } label: { Label("场景切换", systemImage: "square.3.layers.3d") }
                Button { addChannelMute(muted: true) } label: { Label("静音指定通道…", systemImage: "mic.slash") }
                Button { addChannelMute(muted: false) } label: { Label("取消静音指定通道…", systemImage: "mic") }
                Button { addChannelFader() } label: { Label("设置通道推子…", systemImage: "slider.horizontal.3") }
                Button { addDcaFader() } label: { Label("设置 DCA 推子…", systemImage: "slider.horizontal.below.rectangle") }
                Divider()
                Button { addDcaMuteAll() }   label: { Label("全部 DCA 静音", systemImage: "speaker.slash") }
                Button { addDcaUnmuteAll() } label: { Label("全部 DCA 取消静音", systemImage: "speaker.wave.2") }
                Divider()
                Button { addWait() } label: { Label("等待…", systemImage: "timer") }
            } label: {
                Label("添加动作", systemImage: "plus.circle")
            }
        } header: {
            Text("动作 (按顺序执行)")
        } footer: {
            if !editingCard.actions.isEmpty {
                Text("点击动作可修改,左滑删除")
            }
        }
    }

    @ViewBuilder
    private func actionRow(_ action: ShowAction) -> some View {
        HStack {
            switch action.kind {
            case .sceneRecall(let scene, let waitMs):
                Image(systemName: "square.3.layers.3d").foregroundStyle(.blue)
                labeled("场景切换", "切换到场景 \(scene)\(waitMs.map { " · 等待 \($0)ms" } ?? "")")
            case .dcaMute(let index, let mute):
                Image(systemName: mute ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(mute ? .red : .green)
                labeled(mute ? "静音 DCA \(index)" : "取消静音 DCA \(index)", "编组 \(index)")
            case .dcaFader(let index, let value, _, _):
                Image(systemName: "slider.horizontal.below.rectangle").foregroundStyle(.orange)
                labeled("DCA \(index) 推子", "→ \(percent(value)) (\(dbText(value)))")
            case .channelFader(let key, let value, _, _):
                Image(systemName: "slider.horizontal.3").foregroundStyle(.orange)
                labeled("\(channelLabel(key)) 推子", "→ \(percent(value)) (\(dbText(value)))")
            case .channelMute(let key, let mute):
                Image(systemName: mute ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(mute ? .red : .green)
                labeled("\(mute ? "静音" : "取消静音") \(channelLabel(key))", key)
            case .channelGain(let key, let value, _, _):
                Image(systemName: "dial.high").foregroundStyle(.yellow)
                labeled("\(channelLabel(key)) 增益", String(format: "→ %.1f dB", value))
            case .busSend(let key, let sendIndex, let value, _, _):
                Image(systemName: "arrowshape.turn.up.right").foregroundStyle(.indigo)
                labeled("\(channelLabel(key)) → Bus \(sendIndex)", "发送 → \(percent(value)) (\(dbText(value)))")
            case .wait(let seconds):
                Image(systemName: "timer").foregroundStyle(.purple)
                labeled("等待", String(format: "%.1f 秒", seconds))
            default:
                Image(systemName: "gearshape").foregroundStyle(.gray)
                labeled("\(action.kind)", "暂不支持编辑")
            }
        }
    }

    private func labeled(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).fontWeight(.medium)
            Text(subtitle).font(.caption).foregroundColor(.secondary)
        }
    }

    private func channelLabel(_ key: String) -> String {
        if let n = Int(key.split(separator: "/").last ?? "") { return "通道 \(n)" }
        return key
    }

    private func percent(_ v: Double) -> String {
        "\(Int(round(v * 100)))/100"
    }

    private func dbText(_ v: Double) -> String {
        let db = OscAddresses.linearToDb(v)
        return db.isInfinite ? "-∞ dB" : String(format: "%.1f dB", db)
    }

    // MARK: - Fades

    private var fadesSection: some View {
        Section {
            if editingCard.fades.isEmpty {
                Text("暂无渐变。渐变会在所有动作完成后执行:推子从起始值按设定时长匀速推到目标位置。")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(editingCard.fades.indices, id: \.self) { i in
                    Button {
                        editingFadeIndex = i
                        editingFadeDraft = FadeDraft(from: editingCard.fades[i])
                    } label: {
                        fadeRow(editingCard.fades[i])
                    }
                    .foregroundColor(.primary)
                }
                .onDelete { indices in
                    editingCard.fades.remove(atOffsets: indices)
                }
            }

            Button {
                showAddFade = true
            } label: {
                Label("添加推子渐变", systemImage: "plus.circle")
            }
        } header: {
            Text("推子渐变 (动作完成后执行)")
        } footer: {
            if !editingCard.fades.isEmpty {
                Text("点击渐变可修改,左滑删除")
            }
        }
    }

    private func fadeRow(_ fade: ShowFade) -> some View {
        HStack {
            Image(systemName: "chart.line.downtrend.xychart").foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(fadeTitle(fade)).font(.subheadline).fontWeight(.medium)
                Text(fadeSubtitle(fade)).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func fadeTitle(_ fade: ShowFade) -> String {
        switch fade.action.kind {
        case .channelFader(let key, _, _, _):
            return "\(channelLabel(key)) 渐变"
        case .dcaFader(let index, _, _, _):
            return "DCA \(index) 渐变"
        case .channelGain(let key, _, _, _):
            return "\(channelLabel(key)) 增益渐变"
        case .busSend(let key, let bus, _, _, _):
            return "\(channelLabel(key)) → Bus \(bus) 渐变"
        default:
            return "渐变"
        }
    }

    private func fadeSubtitle(_ fade: ShowFade) -> String {
        String(format: "%@ → %@ · %.1f 秒 · %d 步",
               formatFadeValue(fade.fromValue, kind: fade.action.kind),
               formatFadeValue(target(of: fade), kind: fade.action.kind),
               fade.durationSeconds, fade.steps)
    }

    private func formatFadeValue(_ v: Double, kind: ShowActionKind) -> String {
        if case .channelGain = kind {
            return String(format: "%.1f dB", v)
        }
        return "\(percent(v)) (\(dbText(v)))"
    }

    private func target(of fade: ShowFade) -> Double {
        switch fade.action.kind {
        case .channelFader(_, let v, _, _), .dcaFader(_, let v, _, _),
             .channelGain(_, let v, _, _), .busSend(_, _, let v, _, _):
            return v
        default:
            return 0
        }
    }

    // MARK: - Add Helpers

    private func addSceneRecall() {
        let currentMaxScene = editingCard.actions
            .compactMap { if case .sceneRecall(let s, _) = $0.kind { return s }; return nil }
            .max() ?? 0
        editingCard.actions.append(ShowAction.sceneRecall(scene: currentMaxScene + 1))
    }

    private func addChannelMute(muted: Bool) {
        let action = ShowAction.channelMute(channel: .channel(1), muted: muted)
        editingAction = action          // 直接进入编辑,让用户选通道
        editingCard.actions.append(action)
    }

    private func addChannelFader() {
        let action = ShowAction.channelFader(channel: .channel(15), value: 0.75)
        editingAction = action
        editingCard.actions.append(action)
    }

    private func addChannelGain() {
        let action = ShowAction.channelGain(channel: .channel(1), gainDb: 0.0)
        editingAction = action
        editingCard.actions.append(action)
    }

    private func addBusSend() {
        let action = ShowAction.busSend(channel: .channel(1), bus: 1, value: 0.5)
        editingAction = action
        editingCard.actions.append(action)
    }

    private func addDcaFader() {
        let action = ShowAction.dcaFader(group: 1, value: 0.75)
        editingAction = action
        editingCard.actions.append(action)
    }

    private func addWait() {
        let action = ShowAction.delay(seconds: 2.0)
        editingAction = action
        editingCard.actions.append(action)
    }

    private func addDcaMuteAll() {
        for i in 1...8 {
            editingCard.actions.append(.dcaMute(group: i, muted: true))
        }
    }

    private func addDcaUnmuteAll() {
        for i in 1...8 {
            editingCard.actions.append(.dcaMute(group: i, muted: false))
        }
    }
}

// MARK: - Action Editor

private struct ActionEditorView: View {
    let action: ShowAction
    let onSave: (ShowAction) -> Void

    @Environment(\.dismiss) private var dismiss

    // 编辑态 (按 kind 初始化)
    @State private var scene: Int = 1
    @State private var sceneWaitMs: Double = 0
    @State private var channelNumber: Int = 1
    @State private var dcaNumber: Int = 1
    @State private var muteFlag: Bool = true
    @State private var faderValue: Double = 0.75
    @State private var gainDb: Double = 0.0
    @State private var busNumber: Int = 1
    @State private var waitSeconds: Double = 2.0

    init(action: ShowAction, onSave: @escaping (ShowAction) -> Void) {
        self.action = action
        self.onSave = onSave

        switch action.kind {
        case .sceneRecall(let s, let waitMs):
            _scene = State(initialValue: s)
            _sceneWaitMs = State(initialValue: Double(waitMs ?? 0))
        case .dcaFader(let index, let value, _, _):
            _dcaNumber = State(initialValue: index)
            _faderValue = State(initialValue: value)
        case .dcaMute(let index, let mute):
            _dcaNumber = State(initialValue: index)
            _muteFlag = State(initialValue: mute)
        case .channelFader(_, let value, _, _):
            _channelNumber = State(initialValue: channelNum(of: action))
            _faderValue = State(initialValue: value)
        case .channelMute(_, let mute):
            _channelNumber = State(initialValue: channelNum(of: action))
            _muteFlag = State(initialValue: mute)
        case .wait(let seconds):
            _waitSeconds = State(initialValue: seconds)
        default:
            break
        }
    }

    var body: some View {
        Form {
            switch action.kind {
            case .sceneRecall:
                Stepper("场景编号: \(scene)", value: $scene, in: 1...99)
                HStack {
                    Text("切换后等待")
                    Spacer()
                    Text("\(Int(sceneWaitMs)) ms").foregroundColor(.secondary)
                }
                Slider(value: $sceneWaitMs, in: 0...5000, step: 100)
            case .dcaFader:
                Picker("DCA 编组", selection: $dcaNumber) {
                    ForEach(1...8, id: \.self) { Text("DCA \($0)").tag($0) }
                }
                faderSlider
            case .dcaMute:
                Picker("DCA 编组", selection: $dcaNumber) {
                    ForEach(1...8, id: \.self) { Text("DCA \($0)").tag($0) }
                }
                Picker("状态", selection: $muteFlag) {
                    Text("静音").tag(true)
                    Text("取消静音").tag(false)
                }
            case .channelFader:
                channelPicker
                faderSlider
            case .channelMute:
                channelPicker
                Picker("状态", selection: $muteFlag) {
                    Text("静音").tag(true)
                    Text("取消静音").tag(false)
                }
            case .channelGain:
                channelPicker
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("增益")
                        Spacer()
                        Text(String(format: "%.1f dB", gainDb)).foregroundColor(.secondary)
                    }
                    Slider(value: $gainDb, in: -12...60, step: 0.5)
                    Text("X32 话放增益范围 -12 ~ +60 dB,建议按演出实际输入微调。")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            case .busSend:
                channelPicker
                Picker("目标 Bus", selection: $busNumber) {
                    ForEach(1...16, id: \.self) { Text("Bus \($0)").tag($0) }
                }
                faderSlider
            case .wait:
                HStack {
                    Text("等待时长")
                    Spacer()
                    Text(String(format: "%.1f 秒", waitSeconds)).foregroundColor(.secondary)
                }
                Slider(value: $waitSeconds, in: 0...30, step: 0.5)
            default:
                Text("此动作类型暂不支持编辑").foregroundColor(.secondary)
            }
        }
        .navigationTitle("编辑动作")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { save() }
            }
        }
    }

    private var channelPicker: some View {
        Picker("通道", selection: $channelNumber) {
            ForEach(1...32, id: \.self) { Text("通道 \($0)").tag($0) }
        }
    }

    private var faderSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("目标位置")
                Spacer()
                Text("\(Int(round(faderValue * 100)))/100 (\(dbLabel))")
                    .foregroundColor(.secondary)
            }
            Slider(value: $faderValue, in: 0...1, step: 0.01)
        }
        .padding(.vertical, 4)
    }

    private var dbLabel: String {
        let db = OscAddresses.linearToDb(faderValue)
        return db.isInfinite ? "-∞ dB" : String(format: "%.1f dB", db)
    }

    private func channelNum(of action: ShowAction) -> Int {
        switch action.kind {
        case .channelFader(let key, _, _, _), .channelMute(let key, _),
             .channelGain(let key, _, _, _), .busSend(let key, _, _, _, _):
            return Int(key.split(separator: "/").last ?? "") ?? 1
        default:
            return 1
        }
    }

    private func save() {
        let newKind: ShowActionKind
        switch action.kind {
        case .sceneRecall:
            newKind = .sceneRecall(scene: scene, waitMs: sceneWaitMs > 0 ? Int(sceneWaitMs) : nil)
        case .dcaFader(_, _, let mode, let fadeMs):
            newKind = .dcaFader(index: dcaNumber, value: faderValue, mode: mode, fadeMs: fadeMs)
        case .dcaMute:
            newKind = .dcaMute(index: dcaNumber, mute: muteFlag)
        case .channelFader(_, _, let mode, let fadeMs):
            newKind = .channelFader(channelKey: ChannelKey.channel(channelNumber).rawValue,
                                    value: faderValue, mode: mode, fadeMs: fadeMs)
        case .channelMute:
            newKind = .channelMute(channelKey: ChannelKey.channel(channelNumber).rawValue, mute: muteFlag)
        case .wait:
            newKind = .wait(seconds: waitSeconds)
        default:
            onSave(action)   // 不支持的类型原样返回
            dismiss()
            return
        }
        onSave(ShowAction(id: action.id, kind: newKind))
        dismiss()
    }
}

// MARK: - Fade Editor

struct FadeDraft: Identifiable {
    enum Target: String, CaseIterable, Identifiable {
        case channelFader, dcaFader, channelGain, busSend
        var id: String { rawValue }
        var label: String {
            switch self {
            case .channelFader: return "通道推子"
            case .dcaFader: return "DCA 推子"
            case .channelGain: return "通道增益"
            case .busSend: return "Bus 发送"
            }
        }
    }

    let id = UUID()
    var target: Target = .channelFader
    var channelNumber: Int = 15
    var dcaNumber: Int = 1
    var busNumber: Int = 1
    var fromValue: Double = 0.75
    var toValue: Double = 0.30
    var duration: Double = 10.0
    var steps: Int = 20

    init() {}

    init(from fade: ShowFade) {
        switch fade.action.kind {
        case .channelFader(let key, let value, _, _):
            target = .channelFader
            channelNumber = Int(key.split(separator: "/").last ?? "") ?? 15
            toValue = value
        case .dcaFader(let index, let value, _, _):
            target = .dcaFader
            dcaNumber = index
            toValue = value
        case .channelGain(let key, let value, _, _):
            target = .channelGain
            channelNumber = Int(key.split(separator: "/").last ?? "") ?? 1
            toValue = value
        case .busSend(let key, let bus, let value, _, _):
            target = .busSend
            channelNumber = Int(key.split(separator: "/").last ?? "") ?? 1
            busNumber = bus
            toValue = value
        default:
            break
        }
        fromValue = fade.fromValue
        duration = fade.durationSeconds
        steps = fade.steps
    }

    func toShowFade() -> ShowFade {
        let action: ShowAction
        switch target {
        case .channelFader:
            action = ShowAction.channelFader(channel: .channel(channelNumber), value: toValue)
        case .dcaFader:
            action = ShowAction.dcaFader(group: dcaNumber, value: toValue)
        case .channelGain:
            action = ShowAction.channelGain(channel: .channel(channelNumber), gainDb: toValue)
        case .busSend:
            action = ShowAction.busSend(channel: .channel(channelNumber), bus: busNumber, value: toValue)
        }
        return ShowFade(action: action, fromValue: fromValue, durationSeconds: duration, steps: steps)
    }
}

private struct FadeEditorView: View {
    let draft: FadeDraft
    let onSave: (ShowFade) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var target: FadeDraft.Target
    @State private var channelNumber: Int
    @State private var dcaNumber: Int
    @State private var busNumber: Int
    @State private var fromValue: Double
    @State private var toValue: Double
    @State private var duration: Double
    @State private var steps: Int

    init(draft: FadeDraft, onSave: @escaping (ShowFade) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _target = State(initialValue: draft.target)
        _channelNumber = State(initialValue: draft.channelNumber)
        _dcaNumber = State(initialValue: draft.dcaNumber)
        _busNumber = State(initialValue: draft.busNumber)
        _fromValue = State(initialValue: draft.fromValue)
        _toValue = State(initialValue: draft.toValue)
        _duration = State(initialValue: draft.duration)
        _steps = State(initialValue: draft.steps)
    }

    /// 增益渐变使用 dB 语义,其余为 0-1 线性值
    private var isGainTarget: Bool { target == .channelGain }

    var body: some View {
        Form {
            Picker("渐变对象", selection: $target) {
                ForEach(FadeDraft.Target.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            if target == .dcaFader {
                Picker("DCA 编组", selection: $dcaNumber) {
                    ForEach(1...8, id: \.self) { Text("DCA \($0)").tag($0) }
                }
            } else {
                Picker("通道", selection: $channelNumber) {
                    ForEach(1...32, id: \.self) { Text("通道 \($0)").tag($0) }
                }
                if target == .busSend {
                    Picker("目标 Bus", selection: $busNumber) {
                        ForEach(1...16, id: \.self) { Text("Bus \($0)").tag($0) }
                    }
                }
            }

            valueRow("起始值", $fromValue)
            valueRow("目标值", $toValue)

            HStack {
                Text("渐变时长")
                Spacer()
                Text(String(format: "%.1f 秒", duration)).foregroundColor(.secondary)
            }
            Slider(value: $duration, in: 0.5...60, step: 0.5)

            HStack {
                Text("执行步数 (越多人耳越顺滑)")
                Spacer()
                Text("\(steps) 步").foregroundColor(.secondary)
            }
            Slider(value: Binding(get: { Double(steps) }, set: { steps = Int($0) }),
                   in: 5...60, step: 5)

            Section {
                HStack {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(isGainTarget
                         ? "执行时每 \(String(format: "%.2f", duration / Double(max(steps, 1)))) 秒发送一次增益指令,从起始 dB 匀速推到目标 dB。建议起始值设为当前实际增益。"
                         : "执行时每 \(String(format: "%.2f", duration / Double(max(steps, 1)))) 秒发送一次推子指令,从起始位置匀速推到目标位置。建议起始值设为该推子当前的常见位置。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("推子渐变")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    var d = draft
                    d.target = target
                    d.channelNumber = channelNumber
                    d.dcaNumber = dcaNumber
                    d.busNumber = busNumber
                    d.fromValue = fromValue
                    d.toValue = toValue
                    d.duration = duration
                    d.steps = steps
                    onSave(d.toShowFade())
                    dismiss()
                }
            }
        }
    }

    private func valueRow(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(isGainTarget
                     ? String(format: "%.1f dB", value.wrappedValue)
                     : "\(Int(round(value.wrappedValue * 100)))/100 (\(dbText(value.wrappedValue)))")
                    .foregroundColor(.secondary)
            }
            if isGainTarget {
                Slider(value: value, in: -12...60, step: 0.5)
            } else {
                Slider(value: value, in: 0...1, step: 0.01)
            }
        }
        .padding(.vertical, 4)
    }

    private func dbText(_ v: Double) -> String {
        let db = OscAddresses.linearToDb(v)
        return db.isInfinite ? "-∞ dB" : String(format: "%.1f dB", db)
    }
}
