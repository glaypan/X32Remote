import SwiftUI
import X32RemoteCore

struct FxDetailView: View {
    @Environment(AppModel.self) private var appModel
    let fxId: Int

    @State private var showAlgoPicker = false

    private var fx: FxUI? {
        appModel.fxProcessors.first(where: { $0.id == fxId })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header: fader + mute
                headerSection
                Divider()
                // 槽级三件套: 算法 / 开关 / 混合比 (v1.6 起真台支持)
                engineSection
                Divider()
                // 算法参数 (按标定表渲染)
                paramsSection
            }
        }
        .navigationTitle(fx?.label ?? "FX \(fxId)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAlgoPicker) {
            AlgoPickerSheet(fxId: fxId, current: fx?.algoType)
        }
        .onAppear {
            appModel.queryFxDetail(fxId)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text(fx?.label ?? "FX \(fxId)")
                    .font(.title2).bold()
                Spacer()
                if let fx = fx {
                    Text(fx.isMuted ? "MUTED" : dBText(fx.level))
                        .font(.headline.monospacedDigit())
                        .foregroundColor(fx.isMuted ? .red : .secondary)
                }
            }
            .padding(.horizontal)

            if let fx = fx {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { fx.level },
                            set: { v in Task { await appModel.setFxLevel(fxId, level: v) } }
                        ),
                        in: 0...1
                    )
                    .tint(.blue)
                    HStack {
                        Text("-∞").font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Text("+10 dB").font(.caption2).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal)

                Toggle(isOn: Binding(
                    get: { fx.isMuted },
                    set: { v in Task { await appModel.toggleFxMute(fxId, isMuted: v) } }
                )) {
                    Label("Mute", systemImage: "speaker.slash")
                        .foregroundColor(fx.isMuted ? .red : .primary)
                }
                .tint(.red)
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 12)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 算法 / 开关 / 混合比

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "效果算法", systemImage: "slider.horizontal.3")

            if let fx = fx {
                // 当前算法 + 更换入口
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fx.algoLabel)
                            .font(.subheadline.bold())
                        if let t = fx.algoType {
                            Text(t + (fx.algoSpec?.heavy == true ? " · 仅 FX 1-4" : ""))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button("更换算法") { showAlgoPicker = true }
                        .font(.subheadline)
                        .disabled(FxCalibrationStore.shared == nil)
                }

                Toggle(isOn: Binding(
                    get: { fx.isOn },
                    // setFxOn 是 @MainActor (它改 @Published 状态), 而 Binding 的 set
                    // 闭包不是主线程隔离上下文 —— 同步调用编译不过, 跳到 MainActor 再改
                    set: { v in Task { @MainActor in appModel.setFxOn(fxId, on: v) } }
                )) {
                    Label("启用效果", systemImage: "power")
                        .foregroundColor(fx.isOn ? .primary : .secondary)
                }
                .tint(.green)

                // 混合比: 干湿比, 槽级字段 (不在算法参数表里)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("混合比").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int((fx.mix * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { fx.mix },
                            set: { v in Task { @MainActor in appModel.setFxMix(fxId, mix: v) } }
                        ),
                        in: 0...1
                    )
                    .tint(.blue)
                }
            } else {
                loadingText
            }
        }
        .padding()
    }

    // MARK: - 参数

    private var paramsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("参数", systemImage: "dial.medium")
                .font(.headline)
                .padding(.bottom, 4)

            if let fx = fx, let spec = fx.algoSpec {
                if fx.params.isEmpty {
                    loadingText
                } else {
                    ForEach(spec.params, id: \.p) { pspec in
                        paramRow(fx: fx, spec: pspec)
                    }
                }
            } else if let fx = fx, !fx.params.isEmpty {
                // 真台上装了本库没有的算法: 没有标定, 只能给通用 0-1 滑杆
                ForEach(fx.params.keys.sorted(), id: \.self) { key in
                    paramSlider(
                        label: "Param \(key)",
                        value: Binding(
                            get: { fx.params[key] ?? 0 },
                            set: { appModel.setFxParam(fxId, field: "par\(Int(key) ?? 0)", value: $0) }
                        ),
                        range: 0...1
                    )
                }
            } else if fx?.algoType != nil {
                loadingText
            } else {
                Text("这个槽还没装载效果算法")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .padding()
    }

    /// 按标定规格渲染一行参数。数值 = 带量程滑杆, 枚举 = 下拉,
    /// 未设置 (真台没回值) 显"未设置", 滑杆落在量程下限。
    /// (刻意不用 @ViewBuilder: 局部 let 声明在旧版结果构建器里编译不过)
    private func paramRow(fx: FxUI, spec: FxParamSpec) -> some View {
        // 注意键是 OSC 原始段 —— 两位补零字符串 "01" (X32Client 原样存的参数段)
        let key = String(format: "%02d", spec.p)
        let raw = fx.params[key]
        let valueText = raw.map { spec.display($0) } ?? "未设置"

        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(spec.label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(raw == nil ? .orange : .secondary)
            }
            if spec.isEnum {
                Picker("", selection: Binding(
                    get: { Int((raw ?? spec.lo).rounded()) },
                    set: { appModel.setFxParam(fxId, field: spec.field, value: Double($0)) }
                )) {
                    ForEach(0..<max(1, spec.opts?.count ?? 0), id: \.self) { i in
                        Text(spec.opts?[i] ?? "\(i)").tag(i)
                    }
                }
                .pickerStyle(.menu)
                .tint(.blue)
            } else {
                Slider(
                    value: Binding(
                        get: { raw ?? spec.lo },
                        set: { appModel.setFxParam(fxId, field: spec.field, value: $0) }
                    ),
                    in: spec.lo...spec.hi,
                    step: step(for: spec)
                )
                .tint(.blue)
                HStack {
                    Text(rangeText(spec.lo, spec))
                        .font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Text(rangeText(spec.hi, spec))
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Reusable Views

    private func sectionHeader(title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Spacer()
        }
    }

    private func paramSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
                .tint(.blue)
        }
    }

    /// 滑杆步长: 与网页端 fxStep 同语义 —— 取首个让"总档数 ≤ 200"的候选。
    /// 步长太细 (0.001 配 0–20000 Hz) 会产生 2000 万档, 拖拽根本没法用。
    private func step(for spec: FxParamSpec) -> Double {
        let span = abs(spec.hi - spec.lo)
        for st in [0.001, 0.01, 0.05, 0.1, 0.5, 1, 5, 10, 50, 100] where span / st <= 200 {
            return st
        }
        return 1000
    }

    private func rangeText(_ v: Double, _ spec: FxParamSpec) -> String {
        String(format: "%.\(spec.decimals)f", v) + (spec.unit.isEmpty ? "" : " \(spec.unit)")
    }

    private var loadingText: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading...")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 8)
        }
        .padding(.vertical, 8)
    }

    private func dBText(_ level: Float) -> String {
        if level <= 0 { return "-∞" }
        let db = OscAddresses.linearToDb(Double(level))
        if db.isInfinite || db <= -90 { return "-∞" }
        return String(format: "%.1f dB", db)
    }
}

// MARK: - 算法选择器

/// 61 种算法按分类分组; heavy 算法在 FX 5-8 置灰 (真台 DSP 限制, 写进去也被拒)。
private struct AlgoPickerSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let fxId: Int
    let current: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.cat) { group in
                    Section(group.label) {
                        ForEach(group.names, id: \.self) { name in
                            algoRow(name: name)
                        }
                    }
                }
            }
            .navigationTitle("选择算法")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var groups: [(cat: String, label: String, names: [String])] {
        FxCalibrationStore.shared?.algosByCategory() ?? []
    }

    private func algoRow(name: String) -> some View {
        let spec = FxCalibrationStore.shared?.algo(name)
        let allowed = FxCalibrationStore.shared?.slotAllows(fxId, name) ?? false
        return HStack {
            Button {
                Task { @MainActor in
                    appModel.setFxType(fxId, algo: name)
                    dismiss()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spec?.label ?? name)
                            .font(.body)
                            .foregroundColor(allowed ? .primary : .secondary)
                        Text(name + (spec?.heavy == true ? " · 仅 FX 1-4" : ""))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if name == current {
                        Image(systemName: "checkmark")
                            .foregroundColor(.blue)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!allowed)
        }
    }
}

#Preview {
    NavigationStack {
        FxDetailView(fxId: 1)
            .environment(AppModel())
    }
}
