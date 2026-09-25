import SwiftUI
import X32RemoteCore

struct FxDetailView: View {
    @Environment(AppModel.self) private var appModel
    let fxId: Int

    private var fx: FxUI? {
        appModel.fxProcessors.first(where: { $0.id == fxId })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header: fader + mute
                headerSection
                Divider()
                // Parameters
                paramsSection
            }
        }
        .navigationTitle(fx?.label ?? "FX \(fxId)")
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Parameters

    private var paramsSection: some View {
        Group {
            if let fx = fx, !fx.params.isEmpty {
                let sortedParams = fx.params.sorted { $0.key < $1.key }
                VStack(alignment: .leading, spacing: 12) {
                    Label("Parameters", systemImage: "dial")
                        .font(.headline)
                        .padding(.bottom, 4)

                    ForEach(sortedParams, id: \.key) { param, value in
                        paramSlider(label: "Param \(param)", value: value, paramKey: param)
                    }
                }
                .padding()
            } else {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading parameters...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                }
                .padding()
            }
        }
    }

    private func paramSlider(label: String, value: Double, paramKey: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: { appModel.setFxParam(fxId, param: paramKey, value: $0) }
                ),
                in: 0...1
            )
            .tint(.blue)
        }
    }

    private func dBText(_ level: Float) -> String {
        if level <= 0 { return "-∞" }
        let db = OscAddresses.linearToDb(Double(level))
        if db.isInfinite || db <= -90 { return "-∞" }
        return String(format: "%.1f dB", db)
    }
}

#Preview {
    NavigationStack {
        FxDetailView(fxId: 1)
            .environment(AppModel())
    }
}