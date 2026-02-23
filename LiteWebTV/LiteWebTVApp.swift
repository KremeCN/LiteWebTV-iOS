import SwiftUI

@main
struct LiteWebTVApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                .modifier(HideOverlaysModifier())
                .statusBarHidden(true)
        }
    }
}

/// iOS 16+ 才支持 .persistentSystemOverlays(.hidden)
/// iOS 15 上优雅降级，Home 指示条保持可见（不影响使用）
struct HideOverlaysModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.persistentSystemOverlays(.hidden)
        } else {
            content
        }
    }
}
