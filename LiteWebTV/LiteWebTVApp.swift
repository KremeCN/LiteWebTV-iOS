import SwiftUI

@main
struct LiteWebTVApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                .persistentSystemOverlays(.hidden)
                .statusBarHidden(true)
        }
    }
}
