import SwiftUI

/// 推子行组件 - 用于 Channels 和 DCA 页面的可复用控件
///
/// 推子和静音状态完全通过 Binding 驱动 (Binding 的 set 负责发送 OSC),
/// 避免同一操作被重复发送多条消息。
struct FaderRow: View {
    let label: String
    @Binding var level: Float
    @Binding var isMuted: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(label)
                    .font(.headline)

                Spacer()

                Text("\(Int(level * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 50, alignment: .trailing)

                Button {
                    isMuted.toggle()
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(isMuted ? .red : .blue)
                        .frame(width: 30)
                }
                .buttonStyle(.borderless)
            }

            Slider(value: $level, in: 0...1)
                .tint(.blue)
        }
        .padding(.vertical, 4)
    }
}
