import Foundation
import WebKit

/// 判断当前设备是否适合加载央视频网页播放器（依赖 MSE / ManagedMediaSource）。
enum SourceCapability {
    /// 央视频 PC 网页播放器需要 iOS 17.2+ 且 WebKit 暴露 MSE 类 API。
    static var meetsMinimumOSVersion: Bool {
        if #available(iOS 17.2, *) {
            return true
        }
        return false
    }

    /// 在 WKWebView 中探测 MSE 是否可用（需在 WebView 创建后调用）。
    static func probeMediaSourceSupport(in webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard meetsMinimumOSVersion else {
            completion(false)
            return
        }

        let script = """
        (function() {
            return !!(window.MediaSource || window.WebKitMediaSource || window.ManagedMediaSource);
        })();
        """

        webView.evaluateJavaScript(script) { result, _ in
            let supported = (result as? Bool) == true
            DispatchQueue.main.async {
                completion(supported)
            }
        }
    }
}
