import Foundation
import WebKit
import Combine

/// 播放源模式（当前 WebView 实际加载的页面类型）
enum PlaybackMode {
    case yangshipin
    case cctv
}

/// WebView 核心 ViewModel
final class WebViewModel: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var logicalChannels: [LogicalChannel] = []
    @Published var programs: [ProgramItem] = []
    @Published var currentTitle: String = ""
    @Published var shouldDismissSplash: Bool = false
    @Published var currentChannelIndex: Int = 0
    @Published var currentProgramIndex: Int = 0
    @Published private(set) var playbackMode: PlaybackMode = SourceCapability.meetsMinimumOSVersion ? .yangshipin : .cctv
    @Published private(set) var yangshipinPlayable: Bool = SourceCapability.meetsMinimumOSVersion
    @Published var playbackError: String?

    // MARK: - Constants

    private let yangshipinURL = "https://www.yangshipin.cn/tv/home"
    private let pcUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    /// 央视网 liveplayer：`isIPad()` 为真才会走 HTML5（iPhone/iPad UA）；
    /// 同时不能带 `Mobile`，否则页面脚本会跳到 `/m/`。
    /// Macintosh Safari 会被判定成不支持的桌面浏览器。
    private let cctvUserAgent = "Mozilla/5.0 (iPad; CPU OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/604.1"
    private let beijingTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    private let switchDelay: TimeInterval = 3.0
    private var lastSwitchTime: Date = .distantPast
    private var switchStartTime: Date = .distantPast
    private var scheduleTicker: AnyCancellable?

    private var activeCctvSlug: String?
    private var pendingYangshipinDomIndex: Int?
    private var cctvURLOptions: [URL] = []
    private var cctvURLIndex = 0
    private var yangshipinBootstrapInProgress = false
    private var yangshipinBootstrapTimeoutTask: DispatchWorkItem?

    private let yangshipinBootstrapTimeout: TimeInterval = 15.0

    // MARK: - WebView

    private(set) var webView: WKWebView!

    // MARK: - Script Content Cache

    private var bridgeShimScript: String = ""
    private var automationScript: String = ""
    private var cctvAutomationScript: String = ""

    // MARK: - Init

    override init() {
        super.init()
        loadScripts()
        configureWebView()
        startPlaybackRouting()
        startScheduleTicker()
    }

    deinit {
        scheduleTicker?.cancel()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
    }

    // MARK: - Public Helpers

    /// 为指定频道选择播放源。若频道或源发生变化则重新加载并返回 `true`。
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

    // MARK: - Script Loading

    private func loadScripts() {
        if let shimURL = Bundle.main.url(forResource: "bridge_shim", withExtension: "js"),
           let shimContent = try? String(contentsOf: shimURL, encoding: .utf8) {
            bridgeShimScript = shimContent
        }

        if let autoURL = Bundle.main.url(forResource: "automation", withExtension: "js"),
           let autoContent = try? String(contentsOf: autoURL, encoding: .utf8) {
            automationScript = autoContent
        }

        if let cctvURL = Bundle.main.url(forResource: "cctv_automation", withExtension: "js"),
           let cctvContent = try? String(contentsOf: cctvURL, encoding: .utf8) {
            cctvAutomationScript = cctvContent
        }
    }

    // MARK: - WebView Configuration

    private func configureWebView() {
        let config = WKWebViewConfiguration()

        let contentController = WKUserContentController()
        contentController.add(self, name: "bridge")
        contentController.addUserScript(
            WKUserScript(
                source: cctvPlayerCompatScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        config.userContentController = contentController

        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        installContentRules()
    }

    /// 在 liveplayer.js 执行前锁住 `showNoDrmMsg`。
    /// iPad UA 会走 HTML5，但无 hls.js 时该函数会弹出「请使用电脑端或客户端」。
    /// `atDocumentStart` 时空 hostname 也要锁，避免脚本尚未就绪时漏过。
    private var cctvPlayerCompatScript: String {
        """
        (function() {
            var host = String(location.hostname || '').toLowerCase();
            if (host.indexOf('yangshipin') !== -1) {
                return;
            }
            function deny() { return false; }
            try {
                Object.defineProperty(window, 'showNoDrmMsg', {
                    configurable: false,
                    enumerable: false,
                    writable: false,
                    value: deny
                });
            } catch (e) {
                try { window.showNoDrmMsg = deny; } catch (e2) {}
            }
        })();
        """
    }

    // MARK: - Playback Routing

    private func startPlaybackRouting() {
        SourceCapability.probeMediaSourceSupport(in: webView) { [weak self] supported in
            guard let self = self else { return }
            self.yangshipinPlayable = supported
            if supported {
                self.enterYangshipinCapabilityMode()
            } else {
                self.enterCctvOnlyMode(startIndex: 0, markYangshipinUnavailable: true)
            }
        }
    }

    private func enterYangshipinCapabilityMode() {
        playbackMode = .yangshipin
        webView.customUserAgent = pcUserAgent
        beginYangshipinBootstrap()
        loadYangshipinHome()
    }

    private func enterCctvOnlyMode(startIndex: Int, markYangshipinUnavailable: Bool = true) {
        cancelYangshipinBootstrap()
        if markYangshipinUnavailable {
            yangshipinPlayable = false
        }
        playbackMode = .cctv
        webView.customUserAgent = cctvUserAgent
        currentChannelIndex = min(max(startIndex, 0), CCTVCatalog.channels.count - 1)
        logicalChannels = ChannelMerger.cctvOnlyChannels(activeIndex: currentChannelIndex)
        applyLogicalChannel(at: currentChannelIndex)
    }

    private func beginYangshipinBootstrap() {
        yangshipinBootstrapInProgress = true
        yangshipinBootstrapTimeoutTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.yangshipinBootstrapInProgress else { return }
            if self.logicalChannels.isEmpty {
                print("[LiteWebTV] Yangshipin bootstrap timed out, falling back to CCTV")
                self.enterCctvOnlyMode(startIndex: 0, markYangshipinUnavailable: false)
            }
        }
        yangshipinBootstrapTimeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + yangshipinBootstrapTimeout, execute: task)
    }

    private func completeYangshipinBootstrap() {
        yangshipinBootstrapInProgress = false
        yangshipinBootstrapTimeoutTask?.cancel()
        yangshipinBootstrapTimeoutTask = nil
    }

    private func cancelYangshipinBootstrap() {
        yangshipinBootstrapInProgress = false
        yangshipinBootstrapTimeoutTask?.cancel()
        yangshipinBootstrapTimeoutTask = nil
    }

    private func loadYangshipinHome() {
        guard let url = URL(string: yangshipinURL) else { return }
        webView.load(URLRequest(url: url))
    }

    private func applyLogicalChannel(at index: Int) {
        guard index >= 0, index < logicalChannels.count else { return }

        currentChannelIndex = index
        updateActiveChannelHighlight()
        switchStartTime = Date()
        playbackError = nil

        let channel = logicalChannels[index]
        switch channel.selectedSource {
        case .cctv:
            guard let slug = channel.cctvSlug else { return }
            playbackMode = .cctv
            webView.customUserAgent = cctvUserAgent
            pendingYangshipinDomIndex = nil
            loadCctvPage(for: slug)
        case .yangshipin:
            guard let domIndex = channel.yangshipinDomIndex else { return }
            playbackMode = .yangshipin
            webView.customUserAgent = pcUserAgent
            activeCctvSlug = nil
            programs = []
            currentProgramIndex = 0
            loadYangshipinChannel(domIndex: domIndex)
        }
    }

    private func loadYangshipinChannel(domIndex: Int) {
        pendingYangshipinDomIndex = domIndex
        if webView.url?.host?.contains("yangshipin.cn") == true {
            clickYangshipinChannel(domIndex: domIndex)
            pendingYangshipinDomIndex = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.webView.evaluateJavaScript("window.extractData()", completionHandler: nil)
            }
        } else {
            loadYangshipinHome()
        }
    }

    private func loadCctvPage(for slug: String) {
        activeCctvSlug = slug
        cctvURLOptions = CCTVCatalog.pageURLs(for: slug)
        cctvURLIndex = 0
        loadCurrentCctvURL()
        fetchEpg(for: slug)
    }

    private func loadCurrentCctvURL() {
        guard cctvURLIndex < cctvURLOptions.count else {
            playbackError = "该频道暂时无法播放"
            shouldDismissSplash = true
            return
        }
        webView.load(URLRequest(url: cctvURLOptions[cctvURLIndex]))
    }

    private func retryNextCctvURL() {
        cctvURLIndex += 1
        if cctvURLIndex < cctvURLOptions.count {
            loadCurrentCctvURL()
        } else {
            playbackError = "该频道暂时无法播放"
            shouldDismissSplash = true
        }
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

    // MARK: - Content Rules

    private func installContentRules() {
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*\\.woff2"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*\\.woff"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*\\.ttf"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*\\.otf"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*\\.eot"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/fonts/"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "hm\\.baidu\\.com"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "tongji\\.baidu\\.com"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "google-analytics"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "googletagmanager"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "s\\.cnzz\\.com"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "umeng\\.com"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/beacon"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/trace"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/report"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/monitor"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/tracking"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/analytics"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/tongji"], "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/datacenter"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "openapi-trace"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "tracing"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "sentry"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "bugly"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "hotfix"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "crash"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "ad\\.doubleclick"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "pagead"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "adservice"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "adsense"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "adsbygoogle"], "action": ["type": "block"]],
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: rules),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "LiteWebTVBlockList",
            encodedContentRuleList: jsonString
        ) { [weak self] ruleList, _ in
            if let ruleList = ruleList {
                DispatchQueue.main.async {
                    self?.webView.configuration.userContentController.add(ruleList)
                }
            }
        }
    }

    private func startScheduleTicker() {
        scheduleTicker = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.playbackMode == .cctv, let slug = self.activeCctvSlug {
                    self.fetchEpg(for: slug)
                } else if self.playbackMode == .yangshipin {
                    self.refreshCurrentProgram(using: nil)
                }
            }
    }

    // MARK: - EPG (CCTV)

    private func fetchEpg(for slug: String) {
        guard let url = CCTVCatalog.epgURL(for: slug) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else { return }

            guard let response = try? JSONDecoder().decode(CCTVEPGResponse.self, from: data),
                  let channel = response.data?[slug],
                  let entries = channel.list else {
                return
            }

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
            if isCurrent {
                activeIndex = index
            }
        }

        if list.isEmpty {
            programs = []
            currentProgramIndex = 0
            if let liveTitle, !liveTitle.isEmpty {
                setCurrentTitle(liveTitle)
            }
            return
        }

        if activeIndex == 0, list.first?.isCurrent == false {
            activeIndex = entries.indices.last { entries[$0].startTime <= now } ?? 0
            for idx in list.indices {
                list[idx].isCurrent = idx == activeIndex
            }
        }

        programs = list
        currentProgramIndex = activeIndex

        if activeIndex < list.count {
            setCurrentTitle(list[activeIndex].title)
        } else if let liveTitle, !liveTitle.isEmpty {
            setCurrentTitle(liveTitle)
        }
    }

    // MARK: - Script Injection

    private func injectScripts(for mode: PlaybackMode) {
        let consoleBridge = """
        (function() {
            var oldLog = console.log;
            var oldWarn = console.warn;
            var oldError = console.error;
            console.log = function() {
                oldLog.apply(console, arguments);
                var msg = Array.from(arguments).map(String).join(' ');
                window.webkit.messageHandlers.bridge.postMessage({type: 'console', level: 'log', data: msg});
            };
            console.warn = function() {
                oldWarn.apply(console, arguments);
                var msg = Array.from(arguments).map(String).join(' ');
                window.webkit.messageHandlers.bridge.postMessage({type: 'console', level: 'warn', data: msg});
            };
            console.error = function() {
                oldError.apply(console, arguments);
                var msg = Array.from(arguments).map(String).join(' ');
                window.webkit.messageHandlers.bridge.postMessage({type: 'console', level: 'error', data: msg});
            };
        })();
        """

        let platformSpoof = """
        Object.defineProperty(navigator, 'platform', { get: function() { return 'Win32'; } });
        """

        let automation = mode == .cctv ? cctvAutomationScript : automationScript
        let combinedScript: String
        if mode == .cctv {
            combinedScript = consoleBridge + "\n" + bridgeShimScript + "\n" + automation
        } else {
            combinedScript = consoleBridge + "\n" + platformSpoof + "\n" + bridgeShimScript + "\n" + automation
        }

        webView.evaluateJavaScript(combinedScript) { _, error in
            if let error = error {
                print("[LiteWebTV] Script injection error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Channel Switching

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

    private func clickYangshipinChannel(domIndex: Int) {
        let js = """
        (function() {
            const items = document.querySelectorAll('.tv-main-con-r-list-left .oveerflow-1');
            if(items[\(domIndex)]) {
                items[\(domIndex)].click();
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func togglePlayPause() {
        let js = """
        (function(){
            var video = document.querySelector('video');
            if(video){
                if(video.paused){ video.play(); }
                else { video.pause(); }
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func manualInject() {
        injectScripts(for: playbackMode)
    }

    func onDismissSplash() {
        let now = Date()
        if now.timeIntervalSince(switchStartTime) < 1.5 {
            return
        }
        shouldDismissSplash = true
    }

    func resetSplash() {
        shouldDismissSplash = false
        playbackError = nil
    }
}

// MARK: - WKNavigationDelegate

extension WebViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let host = webView.url?.host?.lowercased() ?? ""
        if host.contains("cctv.com") || host.contains("cctv.cn") {
            injectScripts(for: .cctv)
            if let slug = activeCctvSlug {
                fetchEpg(for: slug)
            }
        } else if host.contains("yangshipin.cn") {
            injectScripts(for: .yangshipin)
            if let domIndex = pendingYangshipinDomIndex {
                clickYangshipinChannel(domIndex: domIndex)
                pendingYangshipinDomIndex = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.webView.evaluateJavaScript("window.extractData()", completionHandler: nil)
                }
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    private func handleNavigationFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        if playbackMode == .cctv {
            retryNextCctvURL()
            return
        }
        if playbackMode == .yangshipin && yangshipinBootstrapInProgress {
            print("[LiteWebTV] Yangshipin bootstrap navigation failed, falling back to CCTV")
            enterCctvOnlyMode(startIndex: 0, markYangshipinUnavailable: false)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        let absolute = url.absoluteString.lowercased()

        if scheme == "cntvcbox"
            || scheme == "itms-apps"
            || scheme == "itms"
            || absolute.contains("apps.apple.com")
            || absolute.contains("itunes.apple.com") {
            decisionHandler(.cancel)
            return
        }

        if playbackMode == .cctv, isMobileCctvPath(url.path), isCurrentCctvURLDesktop() {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }
}

// MARK: - WKScriptMessageHandler

extension WebViewModel: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            switch type {
            case "channelList":
                guard self.yangshipinPlayable else { return }
                guard let jsonString = body["data"] as? String,
                      let data = jsonString.data(using: .utf8),
                      let list = try? JSONDecoder().decode([ChannelItem].self, from: data)
                else { return }

                self.updateLogicalChannels(from: list)

            case "programList":
                guard self.playbackMode == .yangshipin else { return }
                guard let jsonString = body["data"] as? String,
                      let data = jsonString.data(using: .utf8),
                      let list = try? JSONDecoder().decode([ProgramItem].self, from: data)
                else { return }

                self.refreshCurrentProgram(using: list)

            case "title":
                if self.playbackMode == .cctv {
                    if let title = body["data"] as? String {
                        self.setCurrentTitle(title)
                    }
                    return
                }
                if !self.programs.isEmpty && self.currentProgramIndex < self.programs.count {
                    self.setCurrentTitle(self.programs[self.currentProgramIndex].title)
                } else if let title = body["data"] as? String {
                    self.setCurrentTitle(title)
                }

            case "dismissSplash":
                self.onDismissSplash()

            case "cctvRestricted":
                guard self.playbackMode == .cctv else { return }
                while self.cctvURLIndex + 1 < self.cctvURLOptions.count,
                      self.isMobileCctvPath(self.cctvURLOptions[self.cctvURLIndex + 1].path) {
                    self.cctvURLIndex += 1
                }
                self.retryNextCctvURL()

            case "console":
                if let level = body["level"] as? String, let msg = body["data"] as? String {
                    print("[JS Console] [\(level.uppercased())] \(msg)")
                }

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

        for idx in list.indices {
            list[idx].isCurrent = (idx == activeIndex)
        }

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
            if minutes <= nowMinutes {
                lastIndex = index
            }
        }
        return lastIndex
    }

    private func isMobileCctvPath(_ path: String) -> Bool {
        path.lowercased().contains("/m/") || path.lowercased().hasSuffix("/m")
    }

    private func isCurrentCctvURLDesktop() -> Bool {
        guard cctvURLIndex < cctvURLOptions.count else { return false }
        return !isMobileCctvPath(cctvURLOptions[cctvURLIndex].path)
    }

    private func parseTimeToMinutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              h >= 0, h <= 23,
              m >= 0, m <= 59 else {
            return nil
        }
        return h * 60 + m
    }
}
