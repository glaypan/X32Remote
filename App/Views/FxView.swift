import SwiftUI

struct FxView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationStack {
            List(Array(appModel.fxProcessors.enumerated()), id: \.element.id) { _, fx in
                NavigationLink(destination: FxDetailView(fxId: fx.id)) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(fx.label)
                                    .font(.headline)
                                // 算法开关小圆点: 绿 = 启用, 灰 = 关闭 (v1.6 起真台有 /fx/<n>/on)
                                Circle()
                                    .fill(fx.isOn ? Color.green : Color(.systemGray3))
                                    .frame(width: 8, height: 8)
                            }
                            Text(rowSubtitle(fx))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        FaderPreview(level: fx.level, isMuted: fx.isMuted)
                            .frame(width: 60, height: 40)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("效果器")
        }
    }

    /// 副标题: 算法中文名 + 参数个数。未装载/未知算法各有说法。
    private func rowSubtitle(_ fx: FxUI) -> String {
        guard fx.algoType != nil else {
            return fx.params.isEmpty ? "未装载" : "未知算法 · \(fx.params.count) 参数"
        }
        var s = fx.algoLabel
        if fx.paramCount > 0 { s += " · \(fx.paramCount) 参数" }
        if !fx.isOn { s += " · 已关闭" }
        return s
    }
}

private struct FaderPreview: View {
    let level: Float
    let isMuted: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.systemGray5))
                    .frame(width: 8)
                RoundedRectangle(cornerRadius: 3)
                    .fill(isMuted ? Color.red.opacity(0.5) : Color.accentColor)
                    .frame(width: 8, height: max(2, CGFloat(level) * geo.size.height))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

#Preview {
    FxView()
        .environment(AppModel())
}
