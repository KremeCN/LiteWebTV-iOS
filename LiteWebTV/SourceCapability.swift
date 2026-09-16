import Foundation
import WebKit

/// 判断当前设备是否适合加载央视频网页播放器（依赖 MSE / ManagedMediaSource）。
enum SourceCapability {
    /// 探测的是「页面播放器能不能找到 MSE 接口」，不是模拟器能不能真正解码 MP4。
    /// 17.4 模拟器上 `ManagedMediaSource` 存在，但 `isTypeSupported(video/mp4)` 为假，
    /// 央视频仍可能黑屏；那是播放问题，不应把 UI 降成央视网-only。
    private static let probeScript = """
    (function() {
        return !!(window.MediaSource || window.WebKitMediaSource || window.ManagedMediaSource);
    })();
    """

    /// 央视频 PC 网页播放器需要 iOS 17.2+ 且 WebKit 暴露 MSE 类 API。
    static var meetsMinimumOSVersion: Bool {
        if #available(iOS 17.2, *) {
            return true
        }
        return false
    }

    /// 当前应走高版本双源布局，还是低版本央视网单源。调试覆盖优先于系统探测。
    static var prefersYangshipinLayout: Bool {
        switch DebugSettings.sourceLayout {
        case .followSystem:
            return meetsMinimumOSVersion
        case .dualSource:
            return true
        case .cctvOnly:
            return false
        }
    }

    /// 在 WKWebView 中探测 MSE 是否可用（需在 WebView 创建后调用）。
    /// 空白页上偶发假阴性时会重试数次。
    static func probeMediaSourceSupport(
        in webView: WKWebView,
        maxAttempts: Int = 3,
        retryDelay: TimeInterval = 0.35,
        completion: @escaping (Bool) -> Void
    ) {
        switch DebugSettings.sourceLayout {
        case .cctvOnly:
            completion(false)
            return
        case .dualSource:
            completion(true)
            return
        case .followSystem:
            break
        }

        guard meetsMinimumOSVersion else {
            completion(false)
            return
        }

        probeAttempt(in: webView, attempt: 1, maxAttempts: max(1, maxAttempts), retryDelay: retryDelay, completion: completion)
    }

    private static func probeAttempt(
        in webView: WKWebView,
        attempt: Int,
        maxAttempts: Int,
        retryDelay: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        webView.evaluateJavaScript(probeScript) { result, error in
            let supported = error == nil && (result as? Bool) == true
            if supported || attempt >= maxAttempts {
                DispatchQueue.main.async {
                    completion(supported)
                }
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
                probeAttempt(
                    in: webView,
                    attempt: attempt + 1,
                    maxAttempts: maxAttempts,
                    retryDelay: retryDelay,
                    completion: completion
                )
            }
        }
    }
}
