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
                        level: Binding(
                            get: { appModel.dcaGroups.first(where: { $0.id == dcaId })?.level ?? 0 },
                            set: { Task { await appModel.setDcaLevel(dcaId, level: $0) } }
                        ),
                        isMuted: Binding(
                            get: { appModel.dcaGroups.first(where: { $0.id == dcaId })?.isMuted ?? false },
                            set: { Task { await appModel.toggleDcaMute(dcaId, isMuted: $0) } }
                        )
                    )
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("DCA")
        }
    }
}

#Preview {
    DcaView()
        .environment(AppModel())
}
