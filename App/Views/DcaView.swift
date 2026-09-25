import SwiftUI

struct DcaView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationStack {
            List(Array(appModel.dcaGroups.enumerated()), id: \.element.id) { _, dca in
                let dcaId = dca.id
                NavigationLink(destination: DcaDetailView(dcaId: dcaId)) {
                    FaderRow(
                        label: dca.label,
                        level: levelBinding(dcaId),
                        isMuted: muteBinding(dcaId)
                    )
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("DCA")
        }
    }

    // 把两个 Binding 单独抽出来，而不是内联在 List 的闭包里 ——
    // 原先整块表达式让编译器直接放弃：
    //   error: the compiler is unable to type-check this expression in reasonable time
    // 显式标注返回类型给类型推断一个锚点，同时也避免 set 闭包里用 $0
    // 时指到内层 Task 的参数列表（Task 闭包不带参数）。
    private func levelBinding(_ dcaId: Int) -> Binding<Float> {
        Binding(
            get: { appModel.dcaGroups.first(where: { $0.id == dcaId })?.level ?? 0 },
            set: { v in Task { await appModel.setDcaLevel(dcaId, level: v) } }
        )
    }

    private func muteBinding(_ dcaId: Int) -> Binding<Bool> {
        Binding(
            get: { appModel.dcaGroups.first(where: { $0.id == dcaId })?.isMuted ?? false },
            set: { v in Task { await appModel.toggleDcaMute(dcaId, isMuted: v) } }
        )
    }
}

#Preview {
    DcaView()
        .environment(AppModel())
}
