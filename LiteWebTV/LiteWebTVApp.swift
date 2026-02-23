import SwiftUI

@main
struct LiteWebTVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                .modifier(HideOverlaysModifier())
                .statusBarHidden(true)
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    // 强制全局横屏，防止 SwiftUI 偶尔忽略 Info.plist 的设置
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .landscape
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
