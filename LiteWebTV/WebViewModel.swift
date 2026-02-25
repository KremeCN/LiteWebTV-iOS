import Foundation
import WebKit
import Combine

/// WebView 核心 ViewModel
/// Maps from Android: WebAppInterface.kt + MainActivity.kt (initWebView, shouldInterceptRequest)
///
/// 职责：
/// 1. 配置 WKWebView（JS 开启、UA 伪装、自动播放）
/// 2. 注入 bridge_shim.js + automation.js
/// 3. 接收 JS 消息（频道列表、节目单、标题、幕布信号）
/// 4. 广告拦截（WKContentRuleList）
/// 5. 频道切换逻辑
final class WebViewModel: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var channels: [ChannelItem] = []
    @Published var programs: [ProgramItem] = []
    @Published var currentTitle: String = ""
    @Published var shouldDismissSplash: Bool = false
    @Published var currentChannelIndex: Int = 0
    @Published var currentProgramIndex: Int = 0

    // MARK: - Constants

    private let targetURL = "https://www.yangshipin.cn/tv/home"
    private let pcUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private let beijingTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    /// 换台防抖保护（3 秒）
    private let switchDelay: TimeInterval = 3.0
    private var lastSwitchTime: Date = .distantPast

    /// 换台开始时间，用于过滤旧视频的播放信号
    private var switchStartTime: Date = .distantPast
    private var scheduleTicker: AnyCancellable?

    // MARK: - WebView

    private(set) var webView: WKWebView!

    // MARK: - Script Content Cache

    private var bridgeShimScript: String = ""
    private var automationScript: String = ""

    // MARK: - Init

    override init() {
        super.init()
        loadScripts()
        configureWebView()
        loadTargetPage()
        startScheduleTicker()
    }

    deinit {
        scheduleTicker?.cancel()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
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
    }

    // MARK: - WebView Configuration

    private func configureWebView() {
        let config = WKWebViewConfiguration()

        // JS 通信桥
        let contentController = WKUserContentController()
        contentController.add(self, name: "bridge")
        config.userContentController = contentController

        // 允许媒体自动播放（不要求用户手势）
        // Maps from Android: webSettings.mediaPlaybackRequiresUserGesture = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = pcUserAgent
        
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        // 设置内容拦截规则（广告/追踪/字体/图片）
        installContentRules()
    }

    // MARK: - Content Rules (Ad-blocking)
    // Maps from Android: shouldInterceptRequest in MainActivity.kt:707-754

    private func installContentRules() {
        // WKContentRuleList 使用 Safari Content Blocker 的 JSON 格式
        let rules: [[String: Any]] = [
            // 1. 字体文件拦截（注意：WebKit Content Blocker 不支持 `?` 量词）
            ["trigger": ["url-filter": ".*\\.woff2"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*\\.woff"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*\\.ttf"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*\\.otf"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*\\.eot"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/fonts/"],
             "action": ["type": "block"]],

            // 2. 统计追踪 & 广告 & 埋点
            // 注意：不拦截图片！WKContentRuleList 无法区分网站 UI 图片和广告图片，
            ["trigger": ["url-filter": "hm\\.baidu\\.com"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "tongji\\.baidu\\.com"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "google-analytics"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "googletagmanager"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "s\\.cnzz\\.com"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "umeng\\.com"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/beacon"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/trace"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/report"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/collect"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/monitor"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/tracking"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/analytics"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/tongji"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": ".*/datacenter"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "openapi-trace"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "tracing"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "sentry"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "bugly"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "hotfix"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "crash"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "ad\\.doubleclick"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "pagead"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "adservice"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "adsense"],
             "action": ["type": "block"]],
            ["trigger": ["url-filter": "adsbygoogle"],
             "action": ["type": "block"]],
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: rules),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "LiteWebTVBlockList",
            encodedContentRuleList: jsonString
        ) { [weak self] ruleList, error in
            if let ruleList = ruleList {
                DispatchQueue.main.async {
                    self?.webView.configuration.userContentController.add(ruleList)
                }
            }
        }
    }

    // MARK: - Page Loading

    private func loadTargetPage() {
        guard let url = URL(string: targetURL) else { return }
        webView.load(URLRequest(url: url))
    }

    private func startScheduleTicker() {
        scheduleTicker = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshCurrentProgram(using: nil)
            }
    }

    // MARK: - Script Injection

    private func injectScripts() {
        // 给 WKWebView 添加 console.log 抓取，用于调试卡加载原因
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
            
            // 顺便覆盖 navigator.platform，伪装得更像 PC
            Object.defineProperty(navigator, 'platform', { get: function() { return 'Win32'; } });
        })();
        """
        
        // 先注入 consoleBridge，再注入 shim，再注入自动化脚本
        let combinedScript = consoleBridge + "\n" + bridgeShimScript + "\n" + automationScript
        webView.evaluateJavaScript(combinedScript) { _, error in
            if let error = error {
                print("[LiteWebTV] Script injection error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Channel Switching

    /// 方向键/手势 快速换台
    /// Maps from Android: MainActivity.kt quickSwitchChannel()
    func quickSwitchChannel(isNext: Bool) -> (allowed: Bool, channelName: String?) {
        guard !channels.isEmpty else { return (false, nil) }

        // 防抖
        let now = Date()
        if now.timeIntervalSince(lastSwitchTime) < switchDelay {
            return (false, nil)
        }
        lastSwitchTime = now

        // 计算目标索引
        var targetListIndex = isNext ? currentChannelIndex + 1 : currentChannelIndex - 1
        if targetListIndex >= channels.count { targetListIndex = 0 }
        if targetListIndex < 0 { targetListIndex = channels.count - 1 }

        let targetItem = channels[targetListIndex]
        currentChannelIndex = targetListIndex
        switchStartTime = Date()

        // 点击 DOM
        let domIndex = targetItem.index
        let js = """
        (function() {
            const items = document.querySelectorAll('.tv-main-con-r-list-left .oveerflow-1');
            if(items[\(domIndex)]) {
                items[\(domIndex)].click();
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        // 延迟 1.5s 后提取数据
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.webView.evaluateJavaScript("window.extractData()", completionHandler: nil)
        }

        return (true, targetItem.name)
    }

    /// 侧边栏点击换台
    /// Maps from Android: MainActivity.kt switchChannel(item)
    func switchChannel(_ item: ChannelItem) -> String {
        let targetName = item.name

        if let listIndex = channels.firstIndex(where: { $0.index == item.index }) {
            currentChannelIndex = listIndex
        }

        switchStartTime = Date()

        let domIndex = item.index
        let js = """
        (function() {
            const items = document.querySelectorAll('.tv-main-con-r-list-left .oveerflow-1');
            if(items[\(domIndex)]) {
                items[\(domIndex)].click();
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.webView.evaluateJavaScript("window.extractData()", completionHandler: nil)
        }

        return targetName
    }

    /// 双击播放/暂停
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

    /// 手动触发脚本注入（菜单键功能）
    func manualInject() {
        injectScripts()
    }

    /// 视频播放信号处理
    func onDismissSplash() {
        // 过滤换台后 1.5 秒内的旧视频信号
        let now = Date()
        if now.timeIntervalSince(switchStartTime) < 1.5 {
            return
        }
        shouldDismissSplash = true
    }

    /// 重置幕布状态（换台前调用）
    func resetSplash() {
        shouldDismissSplash = false
    }
}

// MARK: - WKNavigationDelegate

extension WebViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        injectScripts()
    }
}

// MARK: - WKScriptMessageHandler
// Maps from Android: WebAppInterface.kt

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
                guard let jsonString = body["data"] as? String,
                      let data = jsonString.data(using: .utf8),
                      let list = try? JSONDecoder().decode([ChannelItem].self, from: data)
                else { return }

                self.channels = list
                if let activeIndex = list.firstIndex(where: { $0.isActive }) {
                    self.currentChannelIndex = activeIndex
                }

            case "programList":
                guard let jsonString = body["data"] as? String,
                      let data = jsonString.data(using: .utf8),
                      let list = try? JSONDecoder().decode([ProgramItem].self, from: data)
                else { return }

                self.refreshCurrentProgram(using: list)

            case "title":
                // 废弃原网页不靠谱的 title（受海外浏览器时区干扰）
                // 既然我们在 programList 阶段已经用北京时间绝对算出了正确的当前节目，直接用我们的！
                if !self.programs.isEmpty && self.currentProgramIndex < self.programs.count {
                    self.currentTitle = self.programs[self.currentProgramIndex].title
                } else if let title = body["data"] as? String, !title.isEmpty {
                    self.currentTitle = title // 刚开屏或无节目的兜底
                }

            case "dismissSplash":
                self.onDismissSplash()

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
            let nextTitle = list[activeIndex].title
            if currentTitle != nextTitle {
                currentTitle = nextTitle
            }
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
