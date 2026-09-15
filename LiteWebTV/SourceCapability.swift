import Foundation
import WebKit

/// 判断当前设备是否适合加载央视频网页播放器（依赖 MSE / ManagedMediaSource）。
enum SourceCapability {
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

    /// 在 WKWebView 中探测 MSE 是否可用（需在 WebView 创建后调用）。
    /// 空白页上偶发假阴性时会重试数次。
    static func probeMediaSourceSupport(
        in webView: WKWebView,
        maxAttempts: Int = 3,
        retryDelay: TimeInterval = 0.35,
        completion: @escaping (Bool) -> Void
    ) {
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
