import SwiftUI

struct RootTabView: View {
    @Environment(AppModel.self) private var appModel
    
    var body: some View {
        TabView {
            ChannelsView()
                .tabItem {
                    Label("通道", systemImage: "slider.horizontal.3")
                }
            
            DcaView()
                .tabItem {
                    Label("DCA", systemImage: "rectangle.3.group")
                }
            
            FxView()
                .tabItem {
                    Label("效果器", systemImage: "fx")
                }
            
            ShowsView()
                .tabItem {
                    Label("演出", systemImage: "play.circle")
                }

            RiderView()
                .tabItem {
                    Label("自动", systemImage: "waveform.path.ecg")
                }
            
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
        // 深度链接结果提示：扫到配对码后无论连没连上，都明确告诉用户发生了什么
        .alert(
            appModel.deepLinkNotice?.title ?? "",
            isPresented: Binding(
                get: { appModel.deepLinkNotice != nil },
                set: { if !$0 { appModel.deepLinkNotice = nil } }
            )
        ) {
            Button("好", role: .cancel) { appModel.deepLinkNotice = nil }
        } message: {
            Text(appModel.deepLinkNotice?.message ?? "")
        }
    }
}

#Preview {
    RootTabView()
        .environment(AppModel())
}