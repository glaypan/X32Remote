import SwiftUI
import X32RemoteCore

struct ChannelDetailView: View {
    @Environment(AppModel.self) private var appModel
    let channelId: Int

    private var channel: ChannelUI? {
        appModel.channels.first(where: { $0.id == channelId })
    }

    private let eqTypeNames: [Int: String] = [
        0: "PEQ", 1: "LSH", 2: "HSF", 3: "BPF", 4: "NOTCH", 5: "ALLPASS"
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Channel header
                headerSection
                Divider()
                // EQ section
                eqSection
                Divider()
                // Low Cut section
                lowCutSection
                Divider()
                // Compressor section
                compSection
                Divider()
                // Bus Sends section
                busSendSection
            }
        }
        .navigationTitle(channel?.label ?? "Ch \(channelId)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            appModel.queryChannelDetail(channelId)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text(channel?.label ?? "Ch \(channelId)")
                    .font(.title2).bold()
                Spacer()
                if let ch = channel {
                    Text(ch.isMuted ? "MUTED" : dBText(ch.level))
                        .font(.headline.monospacedDigit())
                        .foregroundColor(ch.isMuted ? .red : .secondary)
                }
            }
            .padding(.horizontal)

            if let ch = channel {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { ch.level },
                            set: { v in Task { await appModel.setChannelLevel(channelId, level: v) } }
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
                    get: { ch.isMuted },
                    set: { v in Task { await appModel.toggleChannelMute(channelId, isMuted: v) } }
                )) {
                    Label("Mute", systemImage: "speaker.slash")
                        .foregroundColor(ch.isMuted ? .red : .primary)
                }
                .tint(.red)
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 12)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - EQ Section

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "EQ", systemImage: "waveform.path.ecg", isOn: Binding(
                get: { channel?.eq?.on ?? false },
                set: { appModel.setEqOn(channelId, on: $0) }
            ))

            if let eq = channel?.eq, eq.on {
                ForEach(0..<eq.bands.count, id: \.self) { idx in
                    eqBandView(band: eq.bands[idx], index: idx + 1)
                }
            } else if channel?.eq == nil {
                loadingText
            }
        }
        .padding()
    }

    private func eqBandView(band: EqBand, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Band \(index)")
                .font(.subheadline.bold())
                .foregroundColor(.secondary)

            // Type picker
            Picker("Type", selection: Binding(
                get: { band.type },
                set: { appModel.setEqBand(channelId, band: index, field: "type", value: Double($0)) }
            )) {
                ForEach(eqTypeNames.keys.sorted(), id: \.self) { key in
                    Text(eqTypeNames[key] ?? "\(key)").tag(key)
                }
            }
            .pickerStyle(.segmented)

            paramSlider(label: "Freq", value: Binding(
                get: { band.freq },
                set: { appModel.setEqBand(channelId, band: index, field: "freq", value: $0) }
            ), range: 20...20000, format: "%.0f Hz", isLog: true)

            paramSlider(label: "Gain", value: Binding(
                get: { band.gain },
                set: { appModel.setEqBand(channelId, band: index, field: "gain", value: $0) }
            ), range: (-15)...15, format: "%.1f dB")

            paramSlider(label: "Q", value: Binding(
                get: { band.q },
                set: { appModel.setEqBand(channelId, band: index, field: "q", value: $0) }
            ), range: 0.1...10, format: "%.2f")

            if index < 4 { Divider() }
        }
    }

    // MARK: - Low Cut Section

    private var lowCutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Low Cut", systemImage: "arrow.down.to.line", isOn: Binding(
                get: { channel?.lowCut?.on ?? false },
                set: { appModel.setLowCutOn(channelId, on: $0) }
            ))

            if let lc = channel?.lowCut, lc.on {
                paramSlider(label: "Frequency", value: Binding(
                    get: { lc.freq },
                    set: { appModel.setLowCutFreq(channelId, freq: $0) }
                ), range: 20...400, format: "%.0f Hz", isLog: true)

                Picker("Slope", selection: Binding(
                    get: { lc.slope },
                    set: { appModel.setLowCutSlope(channelId, slope: $0) }
                )) {
                    ForEach([6, 12, 18, 24, 36, 48], id: \.self) { s in
                        Text("\(s) dB/oct").tag(s)
                    }
                }
                .pickerStyle(.segmented)
            } else if channel?.lowCut == nil {
                loadingText
            }
        }
        .padding()
    }

    // MARK: - Compressor Section

    private var compSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Compressor", systemImage: "compress", isOn: Binding(
                get: { channel?.comp?.on ?? false },
                set: { appModel.setCompOn(channelId, on: $0) }
            ))

            if let comp = channel?.comp, comp.on {
                paramSlider(label: "Threshold", value: Binding(
                    get: { comp.threshold },
                    set: { appModel.setCompParam(channelId, param: "threshold", value: $0) }
                ), range: (-60)...0, format: "%.1f dB")

                paramSlider(label: "Ratio", value: Binding(
                    get: { comp.ratio },
                    set: { appModel.setCompParam(channelId, param: "ratio", value: $0) }
                ), range: 1...50, format: "%.1f:1")

                paramSlider(label: "Knee", value: Binding(
                    get: { comp.knee },
                    set: { appModel.setCompParam(channelId, param: "knee", value: $0) }
                ), range: 0...10, format: "%.1f dB")

                paramSlider(label: "Makeup", value: Binding(
                    get: { comp.makeupGain },
                    set: { appModel.setCompParam(channelId, param: "makeupGain", value: $0) }
                ), range: 0...30, format: "%.1f dB")

                paramSlider(label: "Attack", value: Binding(
                    get: { comp.attack },
                    set: { appModel.setCompParam(channelId, param: "attack", value: $0) }
                ), range: 0.02...200, format: "%.2f ms", isLog: true)

                paramSlider(label: "Hold", value: Binding(
                    get: { comp.hold },
                    set: { appModel.setCompParam(channelId, param: "hold", value: $0) }
                ), range: 0...2000, format: "%.0f ms", isLog: true)

                paramSlider(label: "Release", value: Binding(
                    get: { comp.release },
                    set: { appModel.setCompParam(channelId, param: "release", value: $0) }
                ), range: 2...4000, format: "%.0f ms", isLog: true)
            } else if channel?.comp == nil {
                loadingText
            }
        }
        .padding()
    }

    // MARK: - Bus Sends

    private var busSendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Bus Sends", systemImage: "arrow.triangle.branch")
                .font(.headline)
                .padding(.bottom, 4)

            if appModel.buses.isEmpty {
                loadingText
            } else {
                ForEach(appModel.buses, id: \.id) { bus in
                    HStack(spacing: 8) {
                        Text(bus.label)
                            .font(.caption)
                            .frame(width: 48, alignment: .leading)
                            .foregroundColor(.secondary)

                        Slider(
                            value: Binding(
                                get: { bus.level },
                                set: { appModel.setBusSendLevel(channelId, bus: bus.id, level: $0) }
                            ),
                            in: 0...1
                        )
                        .tint(.blue)

                        Text(bus.isMuted ? "M" : "")
                            .font(.caption2)
                            .foregroundColor(.red)
                            .frame(width: 16)
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - Reusable Views

    private func sectionHeader(title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.blue)
        }
    }

    private func paramSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, isLog: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
                .tint(.blue)
        }
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

#Preview {
    NavigationStack {
        ChannelDetailView(channelId: 1)
            .environment(AppModel())
    }
}