import SwiftUI

@main
struct LiteWebTVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // 缓存在覆写前的真实本地时区（用于界面的双时区显示换算）
    static let realLocalTimeZone = TimeZone.current
    
    init() {
        // 强制全应用（含 WKWebView JS 引擎）使用北京时间 (UTC+8)
        // 解决非东八区用户访问央视网页时，节目单匹配错乱的问题
        NSTimeZone.default = TimeZone(identifier: "Asia/Shanghai")!
    }

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
