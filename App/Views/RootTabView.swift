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
            
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    RootTabView()
        .environment(AppModel())
}