import SwiftUI
import X32RemoteCore

/// 「总线」页：Bus / Aux In / FX 返回 / Matrix / Main 的推子列表。
///
/// 这些通道以前在 App 里根本没有入口（只有 DCA 与效果器页），可它们的均衡、
/// 压缩、插入、发送都是真台的真实能力。这里按登记表里的通道类型列表生成，
/// 点进去就是同一个 `ChannelDetailView` —— 页签按该组能力自动取舍。
struct MixBusesView: View {
    @Environment(AppModel.self) private var appModel

    /// 只列"非输入通道"的那几组（ch 在通道页）
    private let groups = ["bus", "auxin", "fxret", "mtx", "main"]

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.self) { group in
                    if let caps = ParamTable.caps(group) {
                        Section {
                            ForEach(1...max(caps.size, 1), id: \.self) { i in
                                NavigationLink {
                                    ChannelDetailView(channelId: i, group: group, idx: i)
                                } label: {
                                    row(group: group, idx: i, caps: caps)
                                }
                            }
                        } header: {
                            HStack {
                                Text(caps.label)
                                Spacer()
                                Text(capabilityText(caps))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("总线")
        }
    }

    /// 这一组有什么能力，直接写在分组标题上（用户不用点进去才知道）
    private func capabilityText(_ c: ParamGroupCaps) -> String {
        var items: [String] = []
        if c.eq > 0 { items.append("EQ \(c.eq) 段") }
        if c.hasDyn { items.append("压缩") }
        if c.hasGate { items.append("噪声门") }
        if c.hasIns { items.append("插入") }
        if c.hasPan { items.append("声像") }
        if c.hasSend { items.append("\(c.send) 路发送") }
        return items.joined(separator: " · ")
    }

    private func row(group: String, idx: Int, caps: ParamGroupCaps) -> some View {
        FaderRow(
            label: ParamTable.itemLabel(group, idx: idx),
            level: Binding(
                get: { appModel.faderValue(group: group, idx: idx) },
                set: { appModel.setFader(group: group, idx: idx, level: $0) }
            ),
            isMuted: Binding(
                get: { appModel.isMutedValue(group: group, idx: idx) },
                set: { appModel.setMute(group: group, idx: idx, muted: $0) }
            )
        )
    }
}

#Preview {
    MixBusesView()
        .environment(AppModel())
}
