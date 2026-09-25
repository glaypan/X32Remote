import SwiftUI
import X32RemoteCore

struct DcaDetailView: View {
    @Environment(AppModel.self) private var appModel
    let dcaId: Int

    private var dca: DcaUI? {
        appModel.dcaGroups.first(where: { $0.id == dcaId })
    }

    private var allChannels: [ChannelUI] {
        appModel.channels
    }

    private func isMember(_ channel: ChannelUI) -> Bool {
        let bit = 1 << (dcaId - 1)
        return (channel.dcaMask ?? 0) & bit != 0
    }

    private var memberCount: Int {
        allChannels.filter { isMember($0) }.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                Divider()
                membersSection
            }
        }
        .navigationTitle(dca?.label ?? "DCA \(dcaId)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            appModel.queryDcaDetail(dcaId)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text(dca?.label ?? "DCA \(dcaId)")
                    .font(.title2).bold()
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "person.3.fill")
                        .font(.caption)
                    Text("\(memberCount) / 32")
                        .font(.headline.monospacedDigit())
                }
                .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            if let d = dca {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { d.level },
                            set: { Task { await appModel.setDcaLevel(dcaId, level: $0) } }
                        ),
                        in: 0...1
                    )
                    .tint(.orange)
                    HStack {
                        Text("-∞").font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Text("+10 dB").font(.caption2).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal)

                Toggle(isOn: Binding(
                    get: { d.isMuted },
                    set: { Task { await appModel.toggleDcaMute(dcaId, isMuted: $0) } }
                )) {
                    Label("Mute", systemImage: "speaker.slash")
                        .foregroundColor(d.isMuted ? .red : .primary)
                }
                .tint(.red)
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 12)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Members

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Members", subtitle: "Tap to toggle channel membership")

            if allChannels.isEmpty {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading...")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.leading, 8)
                }
                .padding()
            } else {
                ForEach(allChannels) { channel in
                    let isMember = isMember(channel)
                    Button {
                        appModel.toggleChannelDcaMembership(channel.id, dcaId: dcaId)
                    } label: {
                        HStack {
                            Text(String(format: "%02d", channel.id))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 28, alignment: .leading)

                            Text(channel.label)
                                .font(.body)
                                .foregroundColor(.primary)

                            Spacer()

                            Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(isMember ? .orange : .tertiary)
                                .font(.title3)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .background(isMember ? Color.orange.opacity(0.06) : Color.clear)
                    }
                    .buttonStyle(.plain)

                    if channel.id < allChannels.count {
                        Divider().padding(.leading, 48)
                    }
                }
            }
        }
    }

    // MARK: - Reusable

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

#Preview {
    NavigationStack {
        DcaDetailView(dcaId: 1)
            .environment(AppModel())
    }
}