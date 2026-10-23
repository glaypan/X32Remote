import SwiftUI
import X32RemoteCore

/// 自动增益 / 自动推子（Vocal Rider 式）。
///
/// 控制律跑在**电脑端服务**上，手机只做配置与显示（推子模式会真的动推子）。
/// 与网页端共用 `POST /api/rider`，任何一端改完另一端立刻能看到。
struct RiderView: View {
    @AppStorage("rider_host") private var host: String = ""
    @AppStorage("rider_port") private var port: Int = 8080

    @State private var snapshot: RiderSnapshot?
    @State private var errorText: String = ""
    @State private var newChannel: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("电脑 IP（跑服务的那台）", text: $host)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    HStack {
                        Text("网页端口")
                        Spacer()
                        TextField("8080", value: $port, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    if !errorText.isEmpty {
                        Text(errorText).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("电脑端服务")
                } footer: {
                    Text("自动增益需要电脑端在跑服务（同一 WiFi）。没连上时先填 IP 和网页端口。")
                }

                Section {
                    let channels = snapshot?.channels ?? []
                    ForEach(channels) { c in
                        row(c)
                    }
                    if channels.isEmpty {
                        Text("还没有通道。在下面添加，然后打开开关。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("通道 · \((snapshot?.channels ?? []).filter { $0.on }.count) 路启用")
                } footer: {
                    Text("推子模式动推子（电动推子看得见）；增益模式动数字增益，推子不动。")
                }

                Section("添加通道") {
                    HStack {
                        TextField("1-32", text: $newChannel)
                            .keyboardType(.numberPad)
                        Button("添加") { addChannel() }
                            .disabled(Int(newChannel).map { !(1...32).contains($0) } ?? true)
                    }
                }
            }
            .navigationTitle("自动增益")
            .refreshable { await load() }
            .task {
                await load()
                await tickLoop()
            }
        }
    }

    @ViewBuilder
    private func row(_ c: RiderChannel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { c.on },
                set: { v in Task { await post(["channel": c.ch, "on": v]) } }
            )) {
                Text(String(format: "CH%02d", c.ch)).font(.body.weight(.semibold))
            }

            HStack(spacing: 10) {
                Button(c.isGain ? "增益" : "推子") {
                    Task { await post(["channel": c.ch, "mode": c.isGain ? "fader" : "gain"]) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(c.speedLabel) {
                    Task { await post(["channel": c.ch, "speed": nextSpeed(c.speed)]) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(role: .destructive) {
                    Task { await post(["channel": c.ch, "remove": true]) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            Stepper(value: Binding(
                get: { c.target },
                set: { v in Task { await post(["channel": c.ch, "target": v]) } }
            ), in: -60...0, step: 0.5) {
                Text(String(format: "目标 %.1f dBFS", c.effectiveTarget))
                    .font(.caption)
                    .foregroundStyle(c.curve == true ? Color.secondary : Color.primary)
            }
            .disabled(c.curve == true)          // 曲线生效时固定目标不参与

            Text(liveText(c))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func liveText(_ c: RiderChannel) -> String {
        guard let level = c.level else { return "无信号（冻结，不会往上推）" }
        let applied = c.applied.map { String(format: "%+.1f", $0) } ?? "—"
        var s = String(format: "电平 %.1f dBFS · 修正 %@ dB · 目标 %.1f", level, applied, c.effectiveTarget)
        if c.curve == true { s += "（曲线）" }
        if let sc = c.sidechain, sc > 0 { s += String(format: " · 侧链 CH%02d", sc) }
        if c.tap == "pre" { s += " · 推子前" }
        if c.paused == true { s += " · 人工接管中" }
        return s
    }

    private func nextSpeed(_ s: String) -> String {
        switch s {
        case "slow": return "medium"
        case "medium": return "fast"
        default: return "slow"
        }
    }

    private func addChannel() {
        guard let n = Int(newChannel), (1...32).contains(n) else { return }
        newChannel = ""
        Task { await post(["channel": n, "on": true]) }
    }

    private func load() async {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorText = "先填电脑 IP"
            return
        }
        do {
            snapshot = try await RiderAPI.fetch(host: host, port: port)
            errorText = ""
        } catch {
            errorText = "连不上 \(host):\(port)"
        }
    }

    private func post(_ body: [String: Any]) async {
        do {
            snapshot = try await RiderAPI.post(host: host, port: port, body: body)
            errorText = ""
        } catch {
            errorText = "写入失败"
        }
    }

    /// 0.8 秒刷一次实时值；页面消失时随 task 一起取消
    private func tickLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await load()
        }
    }
}

#Preview {
    RiderView()
}
