import SwiftUI

@main
struct X32RemoteApp: App {
    @State private var appModel = AppModel()
    
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appModel)
        }
    }
}
