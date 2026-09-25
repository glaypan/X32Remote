import SwiftUI

struct FxView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationStack {
            List(Array(appModel.fxProcessors.enumerated()), id: \.element.id) { _, fx in
                NavigationLink(destination: FxDetailView(fxId: fx.id)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fx.label)
                                .font(.headline)
                            if !fx.params.isEmpty {
                                Text("\(fx.params.count) 参数")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
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