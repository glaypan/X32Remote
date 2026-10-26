import SwiftUI

@main
struct X32RemoteApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appModel)
                // 系统相机 / 微信扫到 x32remote://pair?... 会拉起 App 并走这里
                .onOpenURL { url in appModel.handleOpenURL(url) }
        }
    }
}
