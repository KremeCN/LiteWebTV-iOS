import Foundation
import WebKit
import Combine
import UIKit

enum PlaybackMode {
    case yangshipin
    case cctv
}

enum VisibleWebSurface {
    case yangshipin
    case cctv
    case probe
}

/// WebView 核心 ViewModel
final class WebViewModel: NSObject, ObservableObject {

    @Published var logicalChannels: [LogicalChannel] = []
    @Published var programs: [ProgramItem] = []
    @Published var currentTitle: String = ""
    @Published var shouldDismissSplash: Bool = false
    @Published var currentChannelIndex: Int = 0
    @Published var currentProgramIndex: Int = 0
    @Published private(set) var playbackMode: PlaybackMode = SourceCapability.prefersYangshipinLayout ? .yangshipin : .cctv
    @Published private(set) var yangshipinPlayable: Bool = SourceCapability.prefersYangshipinLayout
    @Published var playbackError: String?
    @Published var isCompareMode = false
    @Published var probeUseSafariUA = true
    @Published var probeAllowsInlinePlayback = true
    @Published private(set) var probeRevision = 0
    @Published var diagnostics = PlaybackDiagnostics()

    private let yangshipinURL = "https://www.yangshipin.cn/tv/home"
    private let pcUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    /// 受控变量，不是“已证明等同 Safari”的结论。
    private let cctvUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    private let beijingTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    private let switchDelay: TimeInterval = 3.0
    private var lastSwitchTime: Date = .distantPast
    private var switchStartTime: Date = .distantPast
    private var scheduleTicker: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    private var activeCctvSlug: String?
    private var pendingYangshipinDomIndex: Int?
    /// 央视频频道点击必须发生在 CCTV 被挂起之后，避免两路声音叠在一起。
    private var yangshipinReadyToClick = false
    /// 首页若在 WK 媒体挂起/后台态下初始化，后续点台会变成网站的「请求参数错误」。
    private var yangshipinDidInitInBackground = false
    private var yangshipinBootstrapInProgress = false
    private var yangshipinBootstrapTimeoutTask: DispatchWorkItem?
    private var hasAppliedLaunchChannel = false
    private let yangshipinBootstrapTimeout: TimeInterval = 15.0
    private var mediaGeneration = 0
    private var probeSessionID = 0
    private var probeOperationGeneration = 0
    private var activeDiagnosticDocuments: [ObjectIdentifier: Set<String>] = [:]
    private var activeDiagnosticNavigationIDs: [ObjectIdentifier: String] = [:]
    private struct PendingPlaybackOperation {
        let attempt: Int
        let source: String
        let webViewID: ObjectIdentifier
        let navigationID: String?
    }
    private var pendingPlaybackOperations: [String: PendingPlaybackOperation] = [:]
    private var contentRuleList: WKContentRuleList?

    private(set) var yangshipinWebView: WKWebView!
    private(set) var cctvWebView: WKWebView!
    private(set) var probeWebView: WKWebView!
    let nativePlayer = CctvNativePlayer()
    @Published private(set) var nativePlaybackActive = false
    /// 原生 CDN 失败改走网页时，让幕布重新计时，避免 10 秒兜底提前掀开。
    @Published private(set) var splashDeadlineExtend = 0
    private var nativeAttempt = 0
    private var nativeReadyTimeout: DispatchWorkItem?
    private let nativeReadyTimeoutInterval: TimeInterval = 5
    private var cctvPlayKickGeneration = 0

    var visibleSurface: VisibleWebSurface {
        if isCompareMode { return .probe }
        return playbackMode == .cctv ? .cctv : .yangshipin
    }

    private var bridgeShimScript = ""
    private var automationScript = ""
    private var yangshipinGateScript = ""
    private var yangshipinExtractScript = ""
    private var cctvAutomationScript = ""
    private var cctvProbeScript = ""
    private var cctvSwCompatScript = ""
    override init() {
        super.init()
        loadScripts()
        configureWebViews()
        nativePlayer.onReady = { [weak self] in
            self?.handleNativeReady()
        }
        nativePlayer.onFailed = { [weak self] _ in
            self?.failNativeCctv(reason: "player")
        }
        CctvH5eSession.shared.onLog = { [weak self] line in
            self?.diagnostics.log("h5e", line)
        }
        CctvHlsProxy.shared.onLog = { [weak self] line in
            self?.diagnostics.log("hls", line)
        }
        nativePlayer.onVideoSize = { [weak self] size in
            self?.diagnostics.log("h5e", "video size \(Int(size.width))x\(Int(size.height))")
        }
        diagnostics.beginSession("app launch build=\(PlaybackDiagnostics.buildID)")
        diagnostics.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.resumeCctvIfPausedAfterVolume()
            }
            .store(in: &cancellables)
        startPlaybackRouting()
        startScheduleTicker()
    }

    deinit {
        scheduleTicker?.cancel()
        [yangshipinWebView, cctvWebView, probeWebView].forEach { webView in
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "diag")
        }
    }

    @discardableResult
    func selectSource(_ source: StreamSource, at listIndex: Int) -> Bool {
        guard listIndex >= 0, listIndex < logicalChannels.count else { return false }
        let channel = logicalChannels[listIndex]
        guard channel.availableSources.contains(source) else { return false }

        let needsReload = listIndex != currentChannelIndex || channel.selectedSource != source
        SourcePreferenceStore.save(channelId: channel.id, source: source)
        logicalChannels[listIndex].selectedSource = source
        guard needsReload else { return false }

        playbackError = nil
        applyLogicalChannel(at: listIndex)
        return true
    }

    func enterOfficialCompare() {
        guard let slug = activeCctvSlug ?? launchCctvSlug() ?? logicalChannels[safe: currentChannelIndex]?.cctvSlug else {
            diagnostics.log("error", "no CCTV slug for compare mode")
            playbackError = "当前频道没有央视网对照地址"
            return
        }
        probeOperationGeneration += 1
        let operation = probeOperationGeneration
        probeSessionID += 1
        let session = probeSessionID
        diagnostics.beginAttempt(
            "official compare inline=\(probeAllowsInlinePlayback) safariUA=\(probeUseSafariUA) slug=\(slug) session=\(session)"
        )
        let url = CCTVCatalog.pageURLs(for: slug)[0]
        rebuildProbeWebView(operation: operation) { [weak self] webView in
            guard let self, operation == self.probeOperationGeneration else { return }
            self.isCompareMode = true
            self.nativePlayer.pause()
            self.diagnostics.log(
                "nav",
                "probe prepared \(self.diagnostics.redactURLString(url.absoluteString)) session=\(session)"
            )
            self.activate(webView) { [weak self, weak webView] in
                guard let self, let webView,
                      operation == self.probeOperationGeneration,
                      webView === self.probeWebView else { return }
                self.diagnostics.log("nav", "probe load after activation session=\(session)")
                webView.load(URLRequest(url: url))
            }
        }
    }

    func exitOfficialCompare() {
        probeOperationGeneration += 1
        diagnostics.log("session", "exit official compare")
        isCompareMode = false
        probeWebView.stopLoading()
        if nativePlaybackActive {
            nativePlayer.resumeIfPaused()
            return
        }
        activateCurrentNormalWebView()
    }

    func noteProbeConfigurationChanged() {
        diagnostics.log(
            "probe",
            "config changed inline=\(probeAllowsInlinePlayback) safariUA=\(probeUseSafariUA); tap 官方页面对照 to apply"
        )
    }

    func copyDiagnostics() {
        diagnostics.copyToPasteboard()
    }

    func shareDiagnostics() {
        let text = diagnostics.exportedText()
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })?
            .rootViewController else { return }
        var presenter = root
        while let next = presenter.presentedViewController {
            presenter = next
        }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: 48, width: 8, height: 8)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }

    private func loadScripts() {
        if let url = Bundle.main.url(forResource: "bridge_shim", withExtension: "js"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            bridgeShimScript = content
        }
        if let url = Bundle.main.url(forResource: "automation", withExtension: "js"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            automationScript = content
        }
        if let url = Bundle.main.url(forResource: "yangshipin_gate", withExtension: "js"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            yangshipinGateScript = content
        }
        if let url = Bundle.main.url(forResource: "yangshipin_extract", withExtension: "js"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            yangshipinExtractScript = content
        }
        if let url = Bundle.main.url(forResource: "cctv_automation", withExtension: "js"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            cctvAutomationScript = content
        }
        if let url = Bundle.main.url(forResource: "cctv_probe", withExtension: "js"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            cctvProbeScript = content
        }
        if let url = Bundle.main.url(forResource: "cctv_sw_compat", withExtension: "js"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            cctvSwCompatScript = content
        }
    }

    private func configureWebViews() {
        yangshipinWebView = makeWebView(kind: .yangshipin)
        cctvWebView = makeWebView(kind: .cctv)
        probeWebView = makeWebView(kind: .probe)
        yangshipinWebView.customUserAgent = pcUserAgent
        cctvWebView.customUserAgent = cctvUserAgent
        installYangshipinContentRules()
        suspend(yangshipinWebView)
        suspend(cctvWebView)
        suspend(probeWebView)
    }

    private enum WebKind {
        case yangshipin, cctv, probe
    }

    private func makeWebView(kind: WebKind) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: "bridge")
        controller.add(self, name: "diag")
        if kind == .yangshipin, !yangshipinGateScript.isEmpty {
            controller.addUserScript(
                WKUserScript(source: yangshipinGateScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        if kind == .cctv, !cctvSwCompatScript.isEmpty {
            controller.addUserScript(
                WKUserScript(source: cctvSwCompatScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        if kind == .cctv || kind == .probe {
            // Let the official iOS Service Worker initialize before assigning the CDRM source.
            if kind == .probe {
                controller.addUserScript(
                    WKUserScript(
                        source: "window.__lwtvProbeSession=\(probeSessionID);",
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: false
                    )
                )
            }
            controller.addUserScript(
                WKUserScript(source: cctvProbeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
        // All script-enabled views must opt in once WKAppBoundDomains is declared,
        // including Yangshipin, otherwise its injected bridge can be denied.
        config.limitsNavigationsToAppBoundDomains = true
        config.userContentController = controller
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = kind == .probe ? probeAllowsInlinePlayback : true
        config.allowsAirPlayForMediaPlayback = kind != .cctv
        config.allowsPictureInPictureMediaPlayback = kind != .cctv
        config.defaultWebpagePreferences.preferredContentMode = kind == .yangshipin ? .desktop : .mobile

        if kind == .cctv {
            // Hide iOS native media chrome before the official player sets controls.
            let hideNativeChrome = """
            (function(){
                if (window.__lwtvCctvNativeChrome) return;
                window.__lwtvCctvNativeChrome = true;
                var css = 'video::-webkit-media-controls,video::-webkit-media-controls-panel,video::-webkit-media-controls-enclosure,video::-webkit-media-controls-start-playback-button{display:none!important;-webkit-appearance:none!important;opacity:0!important;width:0!important;height:0!important}';
                function inject(){
                    if (document.getElementById('lwtv-cctv-native-chrome')) return;
                    var style = document.createElement('style');
                    style.id = 'lwtv-cctv-native-chrome';
                    style.textContent = css;
                    (document.head || document.documentElement).appendChild(style);
                }
                inject();
                document.addEventListener('DOMContentLoaded', inject);
                // Keep native chrome off without toggling the attribute; toggling it flashes the iOS overlay.
                var proto = HTMLMediaElement.prototype;
                var desc = Object.getOwnPropertyDescriptor(proto, 'controls');
                if (desc && desc.configurable && desc.set) {
                    Object.defineProperty(proto, 'controls', {
                        configurable: true,
                        enumerable: desc.enumerable,
                        get: function () { return false; },
                        set: function () { }
                    });
                }
                var origSetAttribute = Element.prototype.setAttribute;
                Element.prototype.setAttribute = function (name, value) {
                    if (this instanceof HTMLVideoElement && String(name).toLowerCase() === 'controls') return;
                    return origSetAttribute.apply(this, arguments);
                };
            })();
            """
            controller.addUserScript(
                WKUserScript(source: hideNativeChrome, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.isScrollEnabled = kind == .probe
        webView.scrollView.bounces = kind == .probe
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        if kind == .probe {
            webView.customUserAgent = probeUseSafariUA ? cctvUserAgent : nil
        }
        return webView
    }

    private func rebuildProbeWebView(
        operation: Int,
        completion: @escaping (WKWebView) -> Void
    ) {
        let oldProbe = probeWebView
        oldProbe?.stopLoading()
        let finishOldCleanup: () -> Void = { [weak self, weak oldProbe] in
            guard let self else { return }
            oldProbe?.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
            oldProbe?.configuration.userContentController.removeScriptMessageHandler(forName: "diag")
            if let oldProbe {
                self.activeDiagnosticDocuments.removeValue(forKey: ObjectIdentifier(oldProbe))
                oldProbe.removeFromSuperview()
            }
            guard operation == self.probeOperationGeneration else { return }

            let newProbe = self.makeWebView(kind: .probe)
            self.suspend(newProbe, label: "probe-new") { [weak self] in
                guard let self else { return }
                guard operation == self.probeOperationGeneration else {
                    newProbe.stopLoading()
                    newProbe.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
                    newProbe.configuration.userContentController.removeScriptMessageHandler(forName: "diag")
                    return
                }
                self.probeWebView = newProbe
                self.probeRevision += 1
                completion(newProbe)
            }
        }
        if let oldProbe {
            suspend(oldProbe, label: "probe-old", closePresentations: true, completion: finishOldCleanup)
        } else {
            finishOldCleanup()
        }
    }

    private func startPlaybackRouting() {
        SourceCapability.probeMediaSourceSupport(in: yangshipinWebView) { [weak self] supported in
            guard let self else { return }
            self.yangshipinPlayable = supported
            self.diagnostics.log(
                "capability",
                "yangshipin MSE class \(supported) layout=\(DebugSettings.sourceLayout.rawValue)"
            )
            if supported {
                self.enterYangshipinCapabilityMode()
            } else {
                self.enterCctvOnlyMode(markYangshipinUnavailable: true)
            }
        }
    }

    private func enterYangshipinCapabilityMode() {
        if shouldRestoreCctvOnLaunch() {
            playbackMode = .cctv
            if let slug = launchCctvSlug() {
                diagnostics.log("session", "launch restore CCTV \(slug)")
                startNativeCctv(slug: slug)
            }
        } else {
            playbackMode = .yangshipin
            diagnostics.log("session", "launch yangshipin")
        }
        beginYangshipinBootstrap()
        loadYangshipinHome()
        if playbackMode == .yangshipin {
            activate(yangshipinWebView)
        } else if nativePlaybackActive {
            suspend(cctvWebView)
            suspend(yangshipinWebView)
        } else {
            activate(cctvWebView)
        }
    }

    private func shouldRestoreCctvOnLaunch() -> Bool {
        guard let id = SourcePreferenceStore.lastChannelId,
              CCTVCatalog.entry(for: id) != nil else { return false }
        return SourcePreferenceStore.preferredSource(for: id) == .cctv
    }

    private func launchCctvSlug() -> String? {
        guard let id = SourcePreferenceStore.lastChannelId,
              CCTVCatalog.entry(for: id) != nil else { return nil }
        return id
    }

    private func restoredCctvCatalogIndex() -> Int {
        guard let id = SourcePreferenceStore.lastChannelId,
              let index = CCTVCatalog.channels.firstIndex(where: { $0.slug == id }) else {
            return 0
        }
        return index
    }

    private func enterCctvOnlyMode(markYangshipinUnavailable: Bool = true) {
        cancelYangshipinBootstrap()
        if markYangshipinUnavailable {
            yangshipinPlayable = false
        }
        playbackMode = .cctv
        currentChannelIndex = restoredCctvCatalogIndex()
        logicalChannels = ChannelMerger.cctvOnlyChannels(activeIndex: currentChannelIndex)
        applyLogicalChannel(at: currentChannelIndex)
    }

    private func beginYangshipinBootstrap() {
        yangshipinBootstrapInProgress = true
        yangshipinBootstrapTimeoutTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.yangshipinBootstrapInProgress else { return }
            if self.logicalChannels.isEmpty {
                self.diagnostics.log("session", "yangshipin bootstrap timed out")
                self.enterCctvOnlyMode(markYangshipinUnavailable: false)
            }
        }
        yangshipinBootstrapTimeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + yangshipinBootstrapTimeout, execute: task)
    }

    private func completeYangshipinBootstrap() {
        yangshipinBootstrapInProgress = false
        yangshipinBootstrapTimeoutTask?.cancel()
        yangshipinBootstrapTimeoutTask = nil
        if playbackMode == .cctv {
            setYangshipinArmed(false)
            suspend(yangshipinWebView)
        }
    }

    private func cancelYangshipinBootstrap() {
        yangshipinBootstrapInProgress = false
        yangshipinBootstrapTimeoutTask?.cancel()
        yangshipinBootstrapTimeoutTask = nil
    }

    private func loadYangshipinHome() {
        guard let url = URL(string: yangshipinURL) else { return }
        yangshipinWebView.load(URLRequest(url: url))
    }

    private func pauseMedia(in webView: WKWebView) {
        webView.evaluateJavaScript(
            """
            window.__lwtvYangshipinArmed = false;
            document.querySelectorAll('video,audio').forEach(function(m){
                try { m.muted = true; m.volume = 0; m.pause(); } catch(e) {}
            });
            """,
            completionHandler: nil
        )
    }

    private func setYangshipinArmed(_ armed: Bool) {
        yangshipinWebView.evaluateJavaScript(
            "window.__lwtvYangshipinArmed = \(armed ? "true" : "false");",
            completionHandler: nil
        )
        diagnostics.log("media", "yangshipin armed=\(armed)")
    }

    private func suspend(
        _ webView: WKWebView,
        label: String,
        closePresentations: Bool = false,
        completion: @escaping () -> Void
    ) {
        let generation = mediaGeneration
        webView.requestMediaPlaybackState { [weak self] state in
            guard let self, generation == self.mediaGeneration else { return }
            self.diagnostics.log("media", "state before suspend \(label) raw=\(state.rawValue)")
        }
        // 央视频的取流签名会在 `setAllMediaPlaybackSuspended(true)` 期间失效，后台只暂停 DOM 媒体。
        if webView === yangshipinWebView {
            pauseMedia(in: webView)
            diagnostics.log("media", "paused \(label) via js")
            completion()
            return
        }
        webView.setAllMediaPlaybackSuspended(true) { [weak self] in
            guard let self, generation == self.mediaGeneration else { return }
            if closePresentations {
                webView.closeAllMediaPresentations {
                    guard generation == self.mediaGeneration else { return }
                    self.diagnostics.log("media", "suspended \(label) closePresentations=true")
                    completion()
                }
            } else {
                self.diagnostics.log("media", "suspended \(label) closePresentations=false")
                completion()
            }
        }
    }

    private func suspend(_ webView: WKWebView) {
        suspend(webView, label: describe(webView), completion: {})
    }

    private func suspendAllExcept(_ active: WKWebView, completion: @escaping () -> Void) {
        // 三只 WebView 都是 `WKWebView!`；写成数组字面量会被推成 `[WKWebView?]`，这里显式收窄。
        let others = [yangshipinWebView, cctvWebView, probeWebView].compactMap { $0 }.filter { $0 !== active }
        guard !others.isEmpty else {
            completion()
            return
        }
        var remaining = others.count
        for webView in others {
            suspend(webView, label: describe(webView)) {
                remaining -= 1
                if remaining == 0 {
                    completion()
                }
            }
        }
    }

    private func activate(
        _ webView: WKWebView,
        kickPlayback: Bool = true,
        completion: @escaping () -> Void = {}
    ) {
        mediaGeneration += 1
        let generation = mediaGeneration
        let label = describe(webView)
        diagnostics.log("media", "activate requested \(label) gen=\(generation)")
        suspendAllExcept(webView) { [weak self] in
            guard let self else { return }
            guard generation == self.mediaGeneration else {
                self.diagnostics.log("media", "activate aborted stale gen=\(generation)")
                return
            }
            // 被挂起过的页面：必须等 setAllMediaPlaybackSuspended(false) 完成后再 load/play。
            // 在挂起态里创建的 <video> 会一直 NotAllowedError。
            webView.setAllMediaPlaybackSuspended(false) { [weak self] in
                guard let self else { return }
                guard generation == self.mediaGeneration else { return }
                webView.requestMediaPlaybackState { state in
                    guard generation == self.mediaGeneration else { return }
                    self.diagnostics.log("media", "activated \(label) gen=\(generation) state=\(state.rawValue)")
                    if webView === self.yangshipinWebView {
                        self.setYangshipinArmed(self.playbackMode == .yangshipin && !self.isCompareMode)
                        self.yangshipinReadyToClick = true
                        self.flushPendingYangshipinClick()
                    } else {
                        self.setYangshipinArmed(false)
                        self.yangshipinReadyToClick = false
                        if kickPlayback, webView === self.cctvWebView {
                            self.scheduleCctvPlayKick(reason: "activate")
                        }
                    }
                    completion()
                }
            }
        }
    }

    /// 网页 <video> 可能晚于 didFinish 才出现；异步 play() 也必须 await 才能记到日志。
    private func scheduleCctvPlayKick(reason: String) {
        guard playbackMode == .cctv, !nativePlaybackActive, !isCompareMode else { return }
        cctvPlayKickGeneration += 1
        let generation = cctvPlayKickGeneration
        diagnostics.log("media", "play-kick start reason=\(reason) gen=\(generation)")
        for delay in [0.25, 0.8, 1.6, 3.0, 5.0] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      generation == self.cctvPlayKickGeneration,
                      self.playbackMode == .cctv,
                      !self.nativePlaybackActive else { return }
                self.kickCctvVideo(at: delay)
            }
        }
    }

    private func kickCctvVideo(at delay: TimeInterval) {
        let js = """
        var v = document.querySelector('video[id^="h5player_"]') || document.querySelector('video');
        if (!v) return 'no-video';
        if (!v.paused && v.readyState >= 3 && v.currentTime > 0.1) return 'already-playing';
        var src = v.currentSrc || v.src || v.getAttribute('src') || '';
        if (src.length < 8) return 'no-src ready=' + v.readyState;
        try {
            v.setAttribute('playsinline', '');
            v.setAttribute('webkit-playsinline', '');
        } catch (e) {}
        var wantSound = !v.muted;
        v.muted = true;
        try {
            await v.play();
            if (wantSound) {
                try { v.muted = false; } catch (e2) {}
            }
            return 'played ready=' + v.readyState + ' t=' + Math.floor(v.currentTime);
        } catch (err) {
            return 'rejected:' + (err && err.name) + ' ' + String((err && err.message) || '');
        }
        """
        cctvWebView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.diagnostics.log("media", "play-kick t+\(delay) failed \(error.localizedDescription)")
                return
            }
            self.diagnostics.log("media", "play-kick t+\(delay) \(String(describing: value))")
        }
    }

    private func activateCurrentNormalWebView() {
        if nativePlaybackActive { return }
        if playbackMode == .cctv {
            activate(cctvWebView)
        } else {
            activate(yangshipinWebView)
        }
    }

    private func describe(_ webView: WKWebView) -> String {
        if webView === yangshipinWebView { return "yangshipin" }
        if webView === cctvWebView { return "cctv" }
        if webView === probeWebView { return "probe" }
        return "unknown"
    }

    private func applyLogicalChannel(at index: Int) {
        guard index >= 0, index < logicalChannels.count else { return }
        if isCompareMode {
            exitOfficialCompare()
        } else {
            probeOperationGeneration += 1
        }

        currentChannelIndex = index
        updateActiveChannelHighlight()
        switchStartTime = Date()
        playbackError = nil

        let channel = logicalChannels[index]
        SourcePreferenceStore.lastChannelId = channel.id
        SourcePreferenceStore.save(channelId: channel.id, source: channel.selectedSource)
        switch channel.selectedSource {
        case .cctv:
            guard let slug = channel.cctvSlug else { return }
            playbackMode = .cctv
            pendingYangshipinDomIndex = nil
            setYangshipinArmed(false)
            diagnostics.log("session", "switch CCTV native \(slug)")
            startNativeCctv(slug: slug)
        case .yangshipin:
            guard let domIndex = channel.yangshipinDomIndex else { return }
            stopNativeCctv()
            playbackMode = .yangshipin
            activeCctvSlug = nil
            programs = []
            currentProgramIndex = 0
            diagnostics.log("session", "switch yangshipin dom=\(domIndex)")
            loadYangshipinChannel(domIndex: domIndex)
            activate(yangshipinWebView)
        }
    }

    private func loadYangshipinChannel(domIndex: Int) {
        pendingYangshipinDomIndex = domIndex
        let needsReload = yangshipinDidInitInBackground
            || yangshipinWebView.url?.host?.contains("yangshipin.cn") != true
        if needsReload {
            yangshipinDidInitInBackground = false
            diagnostics.log("session", "reload yangshipin after background init")
            loadYangshipinHome()
        } else if yangshipinReadyToClick {
            flushPendingYangshipinClick()
        }
    }

    private func flushPendingYangshipinClick() {
        guard yangshipinReadyToClick,
              playbackMode == .yangshipin,
              let domIndex = pendingYangshipinDomIndex,
              yangshipinWebView.url?.host?.contains("yangshipin.cn") == true,
              !yangshipinWebView.isLoading else { return }
        diagnostics.log("session", "click yangshipin after unsuspend dom=\(domIndex)")
        clickYangshipinChannel(domIndex: domIndex) { [weak self] clicked in
            guard let self,
                  self.playbackMode == .yangshipin,
                  self.pendingYangshipinDomIndex == domIndex else { return }
            // didFinish 并不保证 SPA 已渲染频道列表；失败时保留请求，列表回传后重试。
            guard clicked else { return }
            self.pendingYangshipinDomIndex = nil
            // 点击后前几秒最容易暴露“页面以为在播、实际黑屏”的加载态：
            // 采样 video 的 readyState/networkState/src 和 armed 标志。
            for delay in [0.5, 1.5, 3.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.playbackMode == .yangshipin, !self.nativePlaybackActive else { return }
                    self.yangshipinWebView.evaluateJavaScript(
                        """
                        (function(){
                            var v = document.querySelector('video');
                            if (!v) return 'no-video';
                            return 'ready=' + v.readyState + ' net=' + v.networkState +
                                ' paused=' + v.paused + ' t=' + Math.floor(v.currentTime) +
                                ' dur=' + (isFinite(v.duration) ? Math.floor(v.duration) : -1) +
                                ' src=' + (v.currentSrc ? v.currentSrc.slice(0, 60) : '') +
                                ' armed=' + window.__lwtvYangshipinArmed +
                                ' err=' + (v.error ? (v.error.code + '/' + v.error.message) : 'none');
                        })();
                        """
                    ) { [weak self] result, _ in
                        guard let self, let text = result as? String else { return }
                        self.diagnostics.log("media", "yangshipin video t+\(delay) \(text)")
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.yangshipinWebView.evaluateJavaScript("window.extractData()", completionHandler: nil)
            }
        }
    }

    private func loadCctvPage(for slug: String) {
        activeCctvSlug = slug
        cctvPlayKickGeneration += 1
        guard let url = CCTVCatalog.pageURLs(for: slug).first else { return }
        diagnostics.log("nav", "cctv load \(diagnostics.redactURLString(url.absoluteString))")
        cctvWebView.load(URLRequest(url: url))
        fetchEpg(for: slug)
    }

    private func startNativeCctv(slug: String) {
        if nativePlaybackActive, activeCctvSlug == slug, nativePlayer.player.currentItem != nil {
            fetchEpg(for: slug)
            nativePlayer.resumeIfPaused()
            return
        }
        nativeAttempt += 1
        let attempt = nativeAttempt
        cancelNativeReadyTimeout()
        cctvPlayKickGeneration += 1
        mediaGeneration += 1
        nativePlaybackActive = true
        activeCctvSlug = slug
        pendingYangshipinDomIndex = nil
        setYangshipinArmed(false)
        cctvWebView.stopLoading()
        suspend(cctvWebView)
        suspend(yangshipinWebView)
        fetchEpg(for: slug)
        do {
            try CctvHlsProxy.shared.start(decryptor: CctvH5eSession.shared)
        } catch {
            failNativeCctv(reason: "proxy", attempt: attempt)
            return
        }
        CctvH5eSession.shared.prepare { [weak self] ok in
            guard let self, self.nativeAttempt == attempt, self.activeCctvSlug == slug else { return }
            guard ok, let url = CctvHlsProxy.shared.playURL(for: slug) else {
                CctvH5eSession.shared.teardown()
                self.diagnostics.log("session", "native wasm host failed slug=\(slug); wasm2c fallback not in this build")
                self.failNativeCctv(reason: "wasm", attempt: attempt)
                return
            }
            CctvH5eSession.shared.resetChannel { [weak self] in
                guard let self, self.nativeAttempt == attempt, self.activeCctvSlug == slug, self.nativePlaybackActive else { return }
                self.diagnostics.log("session", "native play \(slug) \(url.port ?? 0)")
                self.nativePlayer.play(url: url)
                self.scheduleNativeReadyTimeout(attempt: attempt)
            }
        }
    }

    private func scheduleNativeReadyTimeout(attempt: Int) {
        cancelNativeReadyTimeout()
        let work = DispatchWorkItem { [weak self] in
            self?.failNativeCctv(reason: "timeout", attempt: attempt)
        }
        nativeReadyTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + nativeReadyTimeoutInterval, execute: work)
    }

    private func cancelNativeReadyTimeout() {
        nativeReadyTimeout?.cancel()
        nativeReadyTimeout = nil
    }

    private func handleNativeReady() {
        guard nativePlaybackActive else { return }
        cancelNativeReadyTimeout()
        shouldDismissSplash = true
    }

    private func failNativeCctv(reason: String, attempt: Int? = nil) {
        if let attempt, attempt != nativeAttempt { return }
        guard nativePlaybackActive, let slug = activeCctvSlug else { return }
        cancelNativeReadyTimeout()
        diagnostics.log("session", "native fail \(slug) reason=\(reason)")
        abandonNativeKeepingSession()
        if CctvNativeCatalog.allowsWebpageFallback(slug), playbackMode == .cctv {
            splashDeadlineExtend += 1
            // 必须等解除挂起完成后再 load。挂起态里起的文档，后面 play() 会一直 NotAllowedError。
            activate(cctvWebView, kickPlayback: false) { [weak self] in
                guard let self,
                      self.playbackMode == .cctv,
                      !self.nativePlaybackActive,
                      self.activeCctvSlug == slug else { return }
                self.loadCctvPage(for: slug)
            }
            return
        }
        playbackError = "该频道暂无法播放"
        shouldDismissSplash = true
    }

    /// 停画面但留下代理和 WASM，方便下一台再走 CDN。
    private func abandonNativeKeepingSession() {
        nativePlaybackActive = false
        nativePlayer.stop()
    }

    private func stopNativeCctv() {
        cancelNativeReadyTimeout()
        nativeAttempt += 1
        guard nativePlaybackActive || nativePlayer.player.currentItem != nil || CctvHlsProxy.shared.port != 0 else { return }
        nativePlaybackActive = false
        nativePlayer.stop()
        CctvH5eSession.shared.teardown()
        CctvHlsProxy.shared.stop()
    }

    private func updateActiveChannelHighlight() {
        for idx in logicalChannels.indices {
            logicalChannels[idx].isActive = idx == currentChannelIndex
        }
    }

    private func updateLogicalChannels(from yangshipinItems: [ChannelItem]) {
        let preserveCctvSelection = playbackMode == .cctv
            && currentChannelIndex < logicalChannels.count
            && logicalChannels[currentChannelIndex].selectedSource == .cctv
        let preservedId = preserveCctvSelection ? logicalChannels[currentChannelIndex].id : nil

        logicalChannels = ChannelMerger.merge(yangshipinItems: yangshipinItems)
        completeYangshipinBootstrap()

        if !hasAppliedLaunchChannel {
            hasAppliedLaunchChannel = true
            if let savedId = SourcePreferenceStore.lastChannelId,
               let listIndex = logicalChannels.firstIndex(where: { $0.id == savedId }) {
                currentChannelIndex = listIndex
            } else if let activeDomIndex = yangshipinItems.firstIndex(where: { $0.isActive }) {
                let domIndex = yangshipinItems[activeDomIndex].index
                if let listIndex = logicalChannels.firstIndex(where: { $0.yangshipinDomIndex == domIndex }) {
                    currentChannelIndex = listIndex
                }
            } else if currentChannelIndex >= logicalChannels.count {
                currentChannelIndex = 0
            }
            updateActiveChannelHighlight()
            if logicalChannels.indices.contains(currentChannelIndex) {
                let channel = logicalChannels[currentChannelIndex]
                if playbackMode == .cctv,
                   channel.selectedSource == .cctv,
                   activeCctvSlug == channel.cctvSlug {
                    return
                }
            }
            applyLogicalChannel(at: currentChannelIndex)
            return
        }

        // 重载后的初始列表通常仍选中 CCTV1，不应覆盖尚未执行的用户选台。
        if playbackMode == .yangshipin, let pendingDomIndex = pendingYangshipinDomIndex {
            if let listIndex = logicalChannels.firstIndex(where: { $0.yangshipinDomIndex == pendingDomIndex }) {
                currentChannelIndex = listIndex
            }
            updateActiveChannelHighlight()
            flushPendingYangshipinClick()
            return
        }

        if preserveCctvSelection, let preservedId,
           let listIndex = logicalChannels.firstIndex(where: { $0.id == preservedId }) {
            currentChannelIndex = listIndex
        } else if let activeDomIndex = yangshipinItems.firstIndex(where: { $0.isActive }) {
            let domIndex = yangshipinItems[activeDomIndex].index
            if let listIndex = logicalChannels.firstIndex(where: { $0.yangshipinDomIndex == domIndex }) {
                currentChannelIndex = listIndex
            }
        } else if currentChannelIndex >= logicalChannels.count {
            currentChannelIndex = 0
        }

        updateActiveChannelHighlight()
    }

    private func installYangshipinContentRules() {
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*\\.woff2"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*\\.woff"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*\\.ttf"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "hm\\.baidu\\.com"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "tongji\\.baidu\\.com"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "google-analytics"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "googletagmanager"], "action": ["type": "block"]],
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: rules),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "LiteWebTVYangshipinBlockList",
            encodedContentRuleList: jsonString
        ) { [weak self] ruleList, _ in
            guard let self, let ruleList else { return }
            DispatchQueue.main.async {
                self.contentRuleList = ruleList
                self.yangshipinWebView.configuration.userContentController.add(ruleList)
            }
        }
    }

    private func startScheduleTicker() {
        scheduleTicker = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                if self.playbackMode == .cctv, let slug = self.activeCctvSlug {
                    self.fetchEpg(for: slug)
                } else if self.playbackMode == .yangshipin {
                    self.refreshCurrentProgram(using: nil)
                }
            }
    }

    private func fetchEpg(for slug: String) {
        guard let url = CCTVCatalog.epgURL(for: slug) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self, let data, error == nil else { return }
            guard let response = try? JSONDecoder().decode(CCTVEPGResponse.self, from: data),
                  let channel = response.data?[slug],
                  let entries = channel.list else { return }
            DispatchQueue.main.async {
                guard self.playbackMode == .cctv, self.activeCctvSlug == slug else { return }
                self.applyEpgEntries(entries, liveTitle: channel.isLive)
            }
        }.resume()
    }

    private func setCurrentTitle(_ title: String) {
        guard !title.isEmpty, currentTitle != title else { return }
        currentTitle = title
    }

    private func applyEpgEntries(_ entries: [CCTVEPGEntry], liveTitle: String?) {
        let now = Int(Date().timeIntervalSince1970)
        var list: [ProgramItem] = []
        var activeIndex = 0
        for (index, entry) in entries.enumerated() {
            let isCurrent = entry.startTime <= now && now < entry.endTime
            list.append(ProgramItem(time: entry.showTime, title: entry.title, isCurrent: isCurrent))
            if isCurrent { activeIndex = index }
        }
        if list.isEmpty {
            programs = []
            currentProgramIndex = 0
            if let liveTitle, !liveTitle.isEmpty { setCurrentTitle(liveTitle) }
            return
        }
        if activeIndex == 0, list.first?.isCurrent == false {
            activeIndex = entries.indices.last { entries[$0].startTime <= now } ?? 0
            for idx in list.indices { list[idx].isCurrent = idx == activeIndex }
        }
        programs = list
        currentProgramIndex = activeIndex
        if activeIndex < list.count {
            setCurrentTitle(list[activeIndex].title)
        } else if let liveTitle, !liveTitle.isEmpty {
            setCurrentTitle(liveTitle)
        }
    }

    private func injectScripts(for mode: PlaybackMode, into target: WKWebView) {
        let consoleBridge = """
        (function() {
            var oldLog = console.log, oldWarn = console.warn, oldError = console.error;
            function fmt(args) {
                var parts = [];
                for (var i = 0; i < args.length; i++) {
                    var a = args[i];
                    try {
                        if (a instanceof Error) {
                            parts.push(a.name + ': ' + a.message + (a.stack ? ' | ' + a.stack : ''));
                        } else if (typeof a === 'object' && a !== null) {
                            parts.push(JSON.stringify(a));
                        } else {
                            parts.push(String(a));
                        }
                    } catch (e) { parts.push('[unserializable]'); }
                }
                return parts.join(' ');
            }
            function send(level, args) {
                window.webkit.messageHandlers.bridge.postMessage({type:'console', level:level, data:fmt(args)});
            }
            console.log = function() { oldLog.apply(console, arguments); send('log', arguments); };
            console.warn = function() { oldWarn.apply(console, arguments); send('warn', arguments); };
            console.error = function() { oldError.apply(console, arguments); send('error', arguments); };
            window.addEventListener('error', function(ev) {
                if (ev && ev.error) {
                    send('error', ['uncaught ' + ev.error.name + ': ' + ev.error.message + (ev.error.stack ? ' | ' + ev.error.stack : '')]);
                } else if (ev && ev.message) {
                    send('error', ['uncaught ' + ev.message + ' @ ' + (ev.filename || '') + ':' + (ev.lineno || 0)]);
                }
            });
            window.addEventListener('unhandledrejection', function(ev) {
                var r = ev && (ev.reason || ev.promise);
                var text = r instanceof Error ? (r.name + ': ' + r.message + (r.stack ? ' | ' + r.stack : '')) : String(r);
                send('error', ['unhandledrejection ' + text]);
            });
        })();
        """
        let combined: String
        if mode == .cctv {
            combined = consoleBridge + "\n" + bridgeShimScript + "\n" + cctvAutomationScript
        } else {
            let platformSpoof = "Object.defineProperty(navigator, 'platform', { get: function() { return 'Win32'; } });"
            let yangshipinBody = (playbackMode == .yangshipin && !isCompareMode)
                ? automationScript
                : yangshipinExtractScript
            combined = consoleBridge + "\n" + platformSpoof + "\n" + bridgeShimScript + "\n" + yangshipinBody
        }
        target.evaluateJavaScript(combined) { _, error in
            if let error {
                let nsError = error as NSError
                self.diagnostics.log("inject", "failed domain=\(nsError.domain) code=\(nsError.code)")
            }
        }
    }

    func quickSwitchChannel(isNext: Bool) -> (allowed: Bool, channelName: String?) {
        guard !logicalChannels.isEmpty else { return (false, nil) }
        let now = Date()
        if now.timeIntervalSince(lastSwitchTime) < switchDelay {
            return (false, nil)
        }
        lastSwitchTime = now
        var targetListIndex = isNext ? currentChannelIndex + 1 : currentChannelIndex - 1
        if targetListIndex >= logicalChannels.count { targetListIndex = 0 }
        if targetListIndex < 0 { targetListIndex = logicalChannels.count - 1 }
        let targetName = logicalChannels[targetListIndex].name
        applyLogicalChannel(at: targetListIndex)
        return (true, targetName)
    }

    func switchChannel(at listIndex: Int) -> String {
        guard listIndex >= 0, listIndex < logicalChannels.count else { return "" }
        let targetName = logicalChannels[listIndex].name
        applyLogicalChannel(at: listIndex)
        return targetName
    }

    private func clickYangshipinChannel(domIndex: Int, completion: @escaping (Bool) -> Void) {
        let js = """
        (function() {
            const items = document.querySelectorAll('.tv-main-con-r-list-left .oveerflow-1');
            const item = items[\(domIndex)];
            if (!item) return false;
            item.click();
            return true;
        })();
        """
        yangshipinWebView.evaluateJavaScript(js) { result, error in
            completion(error == nil && (result as? Bool) == true)
        }
    }

    /// 手势调系统音量可能打断 WKWebView 原生 HLS；若央视网视频因此暂停则恢复。
    func resumeCctvIfPausedAfterVolume() {
        if nativePlaybackActive {
            nativePlayer.resumeIfPaused()
            return
        }
        guard playbackMode == .cctv, !isCompareMode else { return }
        let js = """
        (function(){
            var video = document.querySelector('video[id^="h5player_"]') || document.querySelector('video');
            if (!video || !video.paused) return;
            var src = video.currentSrc || video.src || '';
            if (src.length < 8) return;
            var next = video.play();
            if (next && typeof next.catch === 'function') next.catch(function(){});
        })();
        """
        cctvWebView.evaluateJavaScript(js, completionHandler: nil)
    }

    func togglePlayPause() {
        if nativePlaybackActive {
            nativePlayer.togglePause()
            return
        }
        let target: WKWebView = isCompareMode ? probeWebView : (playbackMode == .cctv ? cctvWebView : yangshipinWebView)
        let operationID = UUID().uuidString
        let targetID = ObjectIdentifier(target)
        let operation = PendingPlaybackOperation(
            attempt: diagnostics.currentAttempt,
            source: describe(target),
            webViewID: targetID,
            navigationID: activeDiagnosticNavigationIDs[targetID]
        )
        pendingPlaybackOperations[operationID] = operation
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self,
                  let expired = self.pendingPlaybackOperations.removeValue(forKey: operationID) else { return }
            self.diagnostics.log(
                "play",
                "app id=\(operationID) source=\(expired.source) result=timeout",
                attempt: expired.attempt
            )
        }
        let js = """
        (function(){
            var operationID = '\(operationID)';
            var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge;
            function report(action, result, errorName) {
                if (bridge) bridge.postMessage({
                    type: 'appPlaybackResult',
                    action: action,
                    result: result,
                    errorName: errorName || '',
                    operationID: operationID
                });
            }
            var video = document.querySelector('video');
            if (!video) {
                report('toggle', 'no-video', '');
                return;
            }
            if (!video.paused) {
                video.pause();
                report('pause', video.paused ? 'paused' : 'not-paused', '');
                return;
            }
            try {
                var promise = video.play();
                if (promise && typeof promise.then === 'function') {
                    promise.then(function(){ report('play', 'resolved', ''); })
                        .catch(function(error){ report('play', 'rejected', error && error.name); });
                } else {
                    report('play', video.paused ? 'still-paused' : 'playing', '');
                }
            } catch (error) {
                report('play', 'threw', error && error.name);
            }
        })();
        """
        diagnostics.log("media", "togglePlayPause requested id=\(operationID) source=\(operation.source)")
        target.evaluateJavaScript(js) { [weak self] _, error in
            guard let self, let error else { return }
            self.pendingPlaybackOperations.removeValue(forKey: operationID)
            self.diagnostics.log(
                "play",
                "injection failed id=\(operationID) source=\(operation.source) type=\(String(describing: type(of: error)))",
                attempt: operation.attempt
            )
        }
    }

    func onDismissSplash() {
        if Date().timeIntervalSince(switchStartTime) < 1.5 { return }
        shouldDismissSplash = true
    }

    func resetSplash() {
        shouldDismissSplash = false
        playbackError = nil
    }
}

extension WebViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let key = ObjectIdentifier(webView)
        activeDiagnosticDocuments[key] = []
        activeDiagnosticNavigationIDs.removeValue(forKey: key)
        diagnostics.log("nav", "didStart \(describe(webView))")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let navigationID = UUID().uuidString
        activeDiagnosticNavigationIDs[ObjectIdentifier(webView)] = navigationID
        if webView === yangshipinWebView {
            setYangshipinArmed(playbackMode == .yangshipin && !isCompareMode)
        }
        guard webView === cctvWebView || webView === probeWebView else { return }
        let js = "window.__lwtvRegisterNativeDocument && window.__lwtvRegisterNativeDocument('\(navigationID)');"
        webView.evaluateJavaScript(js) { [weak self, weak webView] _, error in
            guard let self, let webView else { return }
            if let error {
                let nsError = error as NSError
                self.diagnostics.log(
                    "probe",
                    "native document registration failed source=\(self.describe(webView)) domain=\(nsError.domain) code=\(nsError.code)"
                )
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? ""
        diagnostics.log("nav", "didFinish \(describe(webView)) \(diagnostics.redactURLString(url))")
        if webView === probeWebView {
            diagnostics.log("nav", "probe final \(diagnostics.redactURLString(url)) session=\(probeSessionID)")
            return
        }
        if webView === cctvWebView {
            injectScripts(for: .cctv, into: webView)
            if !nativePlaybackActive {
                // 原生路径里发出的 suspend 可能晚到，这里再解挂一次再 kick play。
                webView.setAllMediaPlaybackSuspended(false) { [weak self] in
                    self?.scheduleCctvPlayKick(reason: "didFinish")
                }
            }
            if let slug = activeCctvSlug { fetchEpg(for: slug) }
            return
        }
        injectScripts(for: .yangshipin, into: webView)
        if playbackMode != .yangshipin {
            yangshipinDidInitInBackground = true
            setYangshipinArmed(false)
            suspend(yangshipinWebView)
        } else {
            yangshipinDidInitInBackground = false
            setYangshipinArmed(true)
            flushPendingYangshipinClick()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(webView, error)
    }

    private func handleNavigationFailure(_ webView: WKWebView, _ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        diagnostics.log("nav", "fail \(describe(webView)) domain=\(nsError.domain) code=\(nsError.code)")
        if webView === cctvWebView {
            playbackError = "央视网页面加载失败"
            shouldDismissSplash = true
            return
        }
        if webView === yangshipinWebView, yangshipinBootstrapInProgress, logicalChannels.isEmpty {
            enterCctvOnlyMode(markYangshipinUnavailable: false)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if webView === yangshipinWebView {
            preferences.preferredContentMode = .desktop
        } else {
            preferences.preferredContentMode = .mobile
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow, preferences)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let absolute = url.absoluteString.lowercased()
        if scheme == "cntvcbox" || scheme == "itms-apps" || scheme == "itms"
            || absolute.contains("apps.apple.com") || absolute.contains("itunes.apple.com") {
            diagnostics.log("nav", "cancel app jump \(diagnostics.redactURLString(url.absoluteString))")
            decisionHandler(.cancel, preferences)
            return
        }
        if webView === probeWebView {
            if scheme == "http" || scheme == "https" {
                diagnostics.log("nav", "probe allow \(diagnostics.redactURLString(url.absoluteString))")
                decisionHandler(.allow, preferences)
                return
            }
            diagnostics.log("nav", "probe cancel non-http \(diagnostics.redactURLString(url.absoluteString))")
            decisionHandler(.cancel, preferences)
            return
        }
        if webView === cctvWebView, isDesktopCctvLiveURL(url) {
            diagnostics.log("nav", "stay on mobile, ignore \(diagnostics.redactURLString(url.absoluteString))")
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }
}

extension WebViewModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "diag" {
            handleDiag(message)
            return
        }
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let fromYangshipin = message.webView === self.yangshipinWebView

            switch type {
            case "channelList":
                guard self.yangshipinPlayable else { return }
                guard fromYangshipin, message.frameInfo.isMainFrame else { return }
                guard let jsonString = body["data"] as? String,
                      let data = jsonString.data(using: .utf8),
                      let list = try? JSONDecoder().decode([ChannelItem].self, from: data)
                else { return }
                self.updateLogicalChannels(from: list)

            case "programList":
                guard self.playbackMode == .yangshipin, !self.isCompareMode else { return }
                guard let jsonString = body["data"] as? String,
                      let data = jsonString.data(using: .utf8),
                      let list = try? JSONDecoder().decode([ProgramItem].self, from: data)
                else { return }
                self.refreshCurrentProgram(using: list)

            case "title":
                if fromYangshipin && self.playbackMode != .yangshipin { return }
                if self.playbackMode == .cctv {
                    if let title = body["data"] as? String { self.setCurrentTitle(title) }
                    return
                }
                if !self.programs.isEmpty && self.currentProgramIndex < self.programs.count {
                    self.setCurrentTitle(self.programs[self.currentProgramIndex].title)
                } else if let title = body["data"] as? String {
                    self.setCurrentTitle(title)
                }

            case "dismissSplash":
                if self.isCompareMode { return }
                if self.nativePlaybackActive { return }
                if fromYangshipin && self.playbackMode != .yangshipin { return }
                self.onDismissSplash()

            case "console":
                if let level = body["level"] as? String, let msg = body["data"] as? String,
                   level == "error" || msg.contains("[CCTV]") {
                    // 原样透传：之前把未知错误折叠成 "filtered console event"，
                    // 央视频卡加载时真正的报错内容全被吞掉，无法定位。
                    self.diagnostics.log("js-\(level)", String(msg.prefix(400)))
                }

            case "appPlaybackResult":
                guard message.frameInfo.isMainFrame,
                      let webView = message.webView,
                      webView === self.yangshipinWebView || webView === self.cctvWebView || webView === self.probeWebView,
                      let operationID = body["operationID"] as? String,
                      let operation = self.pendingPlaybackOperations.removeValue(forKey: operationID),
                      operation.webViewID == ObjectIdentifier(webView),
                      let action = body["action"] as? String,
                      let result = body["result"] as? String else { return }
                let errorName = body["errorName"] as? String ?? ""
                let currentNavigationID = self.activeDiagnosticNavigationIDs[ObjectIdentifier(webView)]
                let navigationStatus = operation.navigationID == currentNavigationID ? "same-navigation" : "navigation-changed"
                self.diagnostics.log(
                    "play",
                    "app id=\(operationID) source=\(operation.source) action=\(action) result=\(result) error=\(errorName) \(navigationStatus)",
                    attempt: operation.attempt
                )

            default:
                break
            }
        }
    }

    private func handleDiag(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let webView = message.webView,
              webView === yangshipinWebView || webView === cctvWebView || webView === probeWebView,
              let documentID = body["documentID"] as? String,
              !documentID.isEmpty else { return }
        DispatchQueue.main.async {
            guard webView === self.yangshipinWebView || webView === self.cctvWebView || webView === self.probeWebView else {
                return
            }
            let key = ObjectIdentifier(webView)
            let source = self.describe(webView)
            let session = body["session"] as? Int ?? 0
            if webView === self.probeWebView, session != self.probeSessionID {
                self.diagnostics.log("probe", "ignored stale session=\(session) current=\(self.probeSessionID)")
                return
            }
            if type == "probeReady" {
                let isMainFrame = (body["mainFrame"] as? Bool) == true
                if isMainFrame {
                    let navigationID = body["navigationID"] as? String ?? ""
                    guard !navigationID.isEmpty,
                          navigationID == self.activeDiagnosticNavigationIDs[key] else {
                        self.diagnostics.log("probe", "ignored obsolete main document on \(source)")
                        return
                    }
                }
                self.activeDiagnosticDocuments[key, default: []].insert(documentID)
            } else if type != "swCompat", self.activeDiagnosticDocuments[key]?.contains(documentID) != true {
                self.diagnostics.log("probe", "ignored stale document on \(source)")
                return
            }
            if type == "documentClosed" {
                self.activeDiagnosticDocuments[key]?.remove(documentID)
                self.diagnostics.log("probe", "document closed on \(source)")
                return
            }

            let href = self.diagnostics.redactURLString(body["href"] as? String ?? "")
            let data = body["data"] as? [String: Any] ?? [:]
            let frame = (body["mainFrame"] as? Bool) == true ? "main" : "sub"
            switch type {
            case "probeReady":
                let ua = body["ua"] as? String ?? ""
                let appVersion = body["appVersion"] as? String ?? ""
                self.diagnostics.log("probe", "\(source) ready frame=\(frame) href=\(href) ua=\(ua) appVersion=\(appVersion)")
            case "video":
                let event = data["event"] as? String ?? "unknown"
                let video = data["video"] as? [String: Any] ?? [:]
                let src = self.diagnostics.redactURLString(video["src"] as? String ?? "")
                let ready = video["ready"] as? Int ?? -1
                let network = video["network"] as? Int ?? -1
                let paused = video["paused"] as? Bool ?? true
                let muted = video["muted"] as? Bool ?? false
                let width = video["w"] as? Int ?? 0
                let height = video["h"] as? Int ?? 0
                let seconds = video["t"] as? Int ?? 0
                let errorCode = (video["error"] as? [String: Any])?["code"] as? Int ?? 0
                self.diagnostics.log(
                    "video",
                    "\(source) frame=\(frame) event=\(event) ready=\(ready) network=\(network) paused=\(paused) muted=\(muted) size=\(width)x\(height) t=\(seconds) error=\(errorCode) src=\(src)"
                )
            case "rightsOverlay":
                let present = data["present"] as? Bool ?? true
                let kind = data["kind"] as? String ?? ""
                let snippet = data["snippet"] as? String ?? ""
                self.diagnostics.log(
                    "overlay",
                    "restricted prompt \(present ? "visible" : "hidden") kind=\(kind) snippet=\(snippet) on \(source) frame=\(frame) href=\(href)"
                )
            case "playerBranch":
                let safari = data["safari"] as? Bool ?? false
                let iosHttps = data["iosHttps"] as? Bool ?? false
                let iosVer = data["iosVer"] as? String ?? ""
                let wasm = data["wasm"] as? Bool ?? false
                let mse = data["mse"] as? Bool ?? false
                let eme = data["eme"] as? Bool ?? false
                let jumpToApp = data["jumpToApp"] as? String ?? ""
                let isDrm = data["isDrm"] as? Bool ?? false
                let isIosDrmFlag = data["isIosDrmFlag"] as? Bool ?? false
                let isIosDrmFn = data["isIosDrmFn"] as? String ?? ""
                let videoUrlKind = data["videoUrlKind"] as? String ?? ""
                let domSrcKind = data["domSrcKind"] as? String ?? ""
                let worker = data["serviceWorker"] as? [String: Any] ?? [:]
                let swAvailable = worker["available"] as? Bool ?? false
                let swControlled = worker["controlled"] as? Bool ?? false
                let swState = worker["state"] as? String ?? ""
                let swScript = worker["script"] as? String ?? ""
                self.diagnostics.log(
                    "player",
                    "\(source) frame=\(frame) safari=\(safari) iosHttps=\(iosHttps) iosVer=\(iosVer) wasm=\(wasm) mse=\(mse) eme=\(eme) jumpToApp=\(jumpToApp) isDrm=\(isDrm) isIosDrmFlag=\(isIosDrmFlag) isIosDrmFn=\(isIosDrmFn) videoUrlKind=\(videoUrlKind) domSrcKind=\(domSrcKind) swAvailable=\(swAvailable) swControlled=\(swControlled) swState=\(swState) swScript=\(swScript)"
                )
            case "pageError":
                let name = data["name"] as? String ?? "Error"
                let path = data["filePath"] as? String ?? ""
                let line = data["line"] as? Int ?? 0
                let column = data["column"] as? Int ?? 0
                self.diagnostics.log("page", "error name=\(name) path=\(path) line=\(line):\(column) source=\(source)")
            case "swCompat":
                let phase = data["phase"] as? String ?? ""
                let scanned = data["scanned"] as? Int ?? 0
                let matched = data["matched"] as? Int ?? 0
                let unregistered = data["unregistered"] as? Int ?? 0
                let scope = data["scope"] as? String ?? ""
                let name = data["name"] as? String ?? ""
                let message = data["message"] as? String ?? ""
                self.diagnostics.log(
                    "sw",
                    "cctv \(phase) scanned=\(scanned) matched=\(matched) unregistered=\(unregistered) scope=\(scope) name=\(name) message=\(message) frame=\(frame) href=\(href)"
                )
            case "unhandledRejection":
                let name = data["name"] as? String ?? "unknown"
                let message = data["message"] as? String ?? ""
                let videoExists = data["videoExists"] as? Bool ?? false
                let srcEmpty = data["srcEmpty"] as? Bool ?? false
                self.diagnostics.log(
                    "page",
                    "unhandled rejection name=\(name) message=\(message) videoExists=\(videoExists) srcEmpty=\(srcEmpty) source=\(source)"
                )
            default:
                break
            }
        }
    }

    private func refreshCurrentProgram(using incomingList: [ProgramItem]?) {
        var list = incomingList ?? programs
        guard !list.isEmpty else {
            programs = []
            currentProgramIndex = 0
            return
        }
        let nowMinutes = currentBeijingMinutes()
        let activeIndex = activeProgramIndex(in: list, nowMinutes: nowMinutes) ?? max(0, list.count - 1)
        for idx in list.indices { list[idx].isCurrent = idx == activeIndex }
        programs = list
        currentProgramIndex = activeIndex
        if activeIndex < list.count {
            setCurrentTitle(list[activeIndex].title)
        }
    }

    private func currentBeijingMinutes() -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijingTimeZone
        let now = Date()
        return calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
    }

    private func activeProgramIndex(in list: [ProgramItem], nowMinutes: Int) -> Int? {
        var lastIndex: Int?
        for (index, item) in list.enumerated() {
            guard let minutes = parseTimeToMinutes(item.time) else { continue }
            if minutes <= nowMinutes { lastIndex = index }
        }
        return lastIndex
    }

    private func isMobileCctvPath(_ path: String) -> Bool {
        path.lowercased().contains("/m/") || path.lowercased().hasSuffix("/m")
    }

    private func isDesktopCctvLiveURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        guard host.contains("cctv.com") || host.contains("cctv.cn") else { return false }
        let path = url.path.lowercased()
        return path.contains("/live/") && !isMobileCctvPath(path)
    }

    private func parseTimeToMinutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
