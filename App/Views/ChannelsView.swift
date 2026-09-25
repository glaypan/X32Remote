import SwiftUI

struct ChannelsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationStack {
            List(Array(appModel.channels.enumerated()), id: \.element.id) { _, channel in
                let channelId = channel.id
                Group {
                    if channelId == AppModel.mainChannelId {
                        // Main LR 没有通道详情页,只提供推子控制
                        row(for: channel, channelId: channelId)
                    } else {
                        NavigationLink(destination: ChannelDetailView(channelId: channelId)) {
                            row(for: channel, channelId: channelId)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("通道")
        }
    }

    @ViewBuilder
    private func row(for channel: ChannelUI, channelId: Int) -> some View {
        HStack(spacing: 8) {
            // Level meter bar
            meterBar(level: channel.meterLevel)
                .frame(width: 4)

            FaderRow(
                label: channel.label,
                level: Binding(
                    get: { appModel.channels.first(where: { $0.id == channelId })?.level ?? 0 },
                    set: { Task { await appModel.setChannelLevel(channelId, level: $0) } }
                ),
                isMuted: Binding(
                    get: { appModel.channels.first(where: { $0.id == channelId })?.isMuted ?? false },
                    set: { Task { await appModel.toggleChannelMute(channelId, isMuted: $0) } }
                )
            )
            .padding(.leading, 4)
        }
    }

    private func meterBar(level: Float) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(.systemGray6))
                // Level fill
                RoundedRectangle(cornerRadius: 2)
                    .fill(meterColor(level))
                    .frame(height: max(2, CGFloat(min(level, 1.0)) * geo.size.height))
                    .animation(.linear(duration: 0.1), value: level)
                // Clip indicator (top 5%)
                if level > 0.95 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red)
                        .frame(height: max(2, geo.size.height * 0.05))
                        .opacity(0.8)
                }
            }
        }
    }

    private func meterColor(_ level: Float) -> Color {
        if level > 0.9 { return .red }
        if level > 0.7 { return .yellow }
        return .green
    }
}

#Preview {
    ChannelsView()
        .environment(AppModel())
}
