import Foundation
import UIKit
import WebKit

/// 隐藏 WKWebView 跑官网 `live.worker.js`，按分片串行调用官方导出。
/// wasm2c 只在这套宿主初始化失败或跟不上直播时再评估，本阶段不编进 App。
final class CctvH5eSession: NSObject, WKNavigationDelegate {
    static let shared = CctvH5eSession()

    private var webView: WKWebView?
    private var readyContinuations: [(Bool) -> Void] = []
    private var prepared = false
    private var busy = false
    private var queue: [(Data, (Data?) -> Void)] = []
    private var generation = 0

    func prepare(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            if self.prepared, self.webView != nil {
                completion(true)
                return
            }
            self.readyContinuations.append(completion)
            guard self.webView == nil else { return }
            self.buildWebView()
        }
    }

    func resetChannel(completion: (() -> Void)? = nil) {
        let work = { [weak self] in
            guard let self else {
                completion?()
                return
            }
            self.dropPending()
            guard let webView = self.webView else {
                completion?()
                return
            }
            webView.evaluateJavaScript("window.__lwtvH5e && window.__lwtvH5e.start()") { _, _ in
                completion?()
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript("window.__lwtvH5e && window.__lwtvH5e.stop()", completionHandler: nil)
            self.dropPending()
        }
    }

    func teardown() {
        let work = { [weak self] in
            guard let self else { return }
            self.webView?.evaluateJavaScript("window.__lwtvH5e && window.__lwtvH5e.stop()", completionHandler: nil)
            self.dropPending()
            self.prepared = false
            self.webView?.navigationDelegate = nil
            self.webView?.stopLoading()
            self.webView?.removeFromSuperview()
            self.webView = nil
            self.finishPrepare(false)
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    func decrypt(_ data: Data, completion: @escaping (Data?) -> Void) {
        DispatchQueue.main.async {
            guard self.prepared, self.webView != nil else {
                completion(nil)
                return
            }
            self.queue.append((data, completion))
            self.pump()
        }
    }

    private func dropPending() {
        generation += 1
        let pending = queue
        queue.removeAll()
        busy = false
        pending.forEach { $0.1(nil) }
    }

    private func buildWebView() {
        let config = WKWebViewConfiguration()
        config.limitsNavigationsToAppBoundDomains = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.processPool = WKProcessPool()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: config)
        webView.isHidden = true
        webView.navigationDelegate = self
        self.webView = webView
        attachIfNeeded()
        guard CctvHlsProxy.shared.port != 0 else {
            finishPrepare(false)
            return
        }
        let url = URL(string: "\(CctvHlsProxy.shared.loopbackOrigin)/h5e.html")!
        webView.load(URLRequest(url: url))
    }

    private func attachIfNeeded() {
        guard let webView, webView.superview == nil else { return }
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIApplication.shared.windows.first {
            webView.frame = CGRect(x: -16, y: -16, width: 8, height: 8)
            window.addSubview(webView)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pollReady(attempts: 0)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishPrepare(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishPrepare(false)
    }

    private func pollReady(attempts: Int) {
        attachIfNeeded()
        guard attempts < 80 else {
            finishPrepare(false)
            return
        }
        webView?.evaluateJavaScript("!!(window.__lwtvH5e && window.__lwtvH5e.isReady())") { [weak self] result, _ in
            guard let self else { return }
            if (result as? Bool) == true {
                self.webView?.evaluateJavaScript("window.__lwtvH5e.start()") { _, error in
                    self.prepared = error == nil
                    self.finishPrepare(self.prepared)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.pollReady(attempts: attempts + 1)
            }
        }
    }

    private func finishPrepare(_ ok: Bool) {
        let waiting = readyContinuations
        readyContinuations = []
        waiting.forEach { $0(ok) }
    }

    private func pump() {
        guard !busy, prepared, let item = queue.first else { return }
        busy = true
        queue.removeFirst()
        guard let webView else {
            item.1(nil)
            busy = false
            pump()
            return
        }
        let id = UUID().uuidString
        let token = generation
        CctvHlsProxy.shared.storeInbox(item.0, id: id)
        let js = "return await window.__lwtvH5e.decryptInbox('\(id)');"
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            defer {
                self.busy = false
                self.pump()
            }
            guard token == self.generation else { return }
            var output: Data?
            switch result {
            case .success(let value):
                if (value as? String) == "ok" {
                    output = CctvHlsProxy.shared.takeOutbox(id: id)
                }
            case .failure:
                output = nil
            }
            item.1(output)
        }
    }
}
