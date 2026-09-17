import SwiftUI
import WebKit

// MARK: - WKWebView UIViewRepresentable Wrapper

struct PlayerWebViewContainer: UIViewRepresentable {
    let yangshipinWebView: WKWebView
    let cctvWebView: WKWebView
    let probeWebView: WKWebView
    var surface: VisibleWebSurface
    var probeRevision: Int

    func makeUIView(context: Context) -> PlayerWebViewHost {
        let host = PlayerWebViewHost()
        host.apply(
            yangshipin: yangshipinWebView,
            cctv: cctvWebView,
            probe: probeWebView,
            surface: surface
        )
        return host
    }

    func updateUIView(_ host: PlayerWebViewHost, context: Context) {
        host.apply(
            yangshipin: yangshipinWebView,
            cctv: cctvWebView,
            probe: probeWebView,
            surface: surface
        )
    }
}

final class PlayerWebViewHost: UIView {
    private weak var yangshipin: WKWebView?
    private weak var cctv: WKWebView?
    private weak var probe: WKWebView?

    func apply(yangshipin: WKWebView, cctv: WKWebView, probe: WKWebView, surface: VisibleWebSurface) {
        attach(&self.yangshipin, yangshipin, interactive: false)
        attach(&self.cctv, cctv, interactive: false)
        attach(&self.probe, probe, interactive: surface == .probe)
        self.yangshipin?.isHidden = surface != .yangshipin
        self.cctv?.isHidden = surface != .cctv
        self.probe?.isHidden = surface != .probe
        switch surface {
        case .yangshipin: if let view = self.yangshipin { bringSubviewToFront(view) }
        case .cctv: if let view = self.cctv { bringSubviewToFront(view) }
        case .probe: if let view = self.probe { bringSubviewToFront(view) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        yangshipin?.frame = bounds
        cctv?.frame = bounds
        probe?.frame = bounds
    }

    private func attach(_ slot: inout WKWebView?, _ webView: WKWebView, interactive: Bool) {
        if slot !== webView {
            slot?.removeFromSuperview()
            webView.removeFromSuperview()
            addSubview(webView)
            slot = webView
        }
        webView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.insetsLayoutMarginsFromSafeArea = false
        webView.scrollView.insetsLayoutMarginsFromSafeArea = false
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = bounds
        webView.isUserInteractionEnabled = interactive
        webView.scrollView.isScrollEnabled = interactive
        webView.scrollView.bounces = interactive
        webView.scrollView.panGestureRecognizer.isEnabled = interactive
    }
}

// MARK: - Main Content View

/// 主视图 — 全部 UI 层的组装
/// Maps from Android: activity_main.xml + MainActivity.kt (UI logic)
///
/// 层级（从底到顶）:
/// 1. WKWebView（视频播放）
/// 2. 频道列表侧边栏（左）
/// 3. 节目单侧边栏（右）
/// 4. 手势检测层
/// 5. 音量/亮度指示器（中央）
/// 6. 标题提示条（顶部中央）
/// 7. 开屏幕布（全屏覆盖）
struct ContentView: View {
    @StateObject private var viewModel = WebViewModel()

    // 侧边栏状态
    @State private var showChannelSidebar = false
    @State private var showProgramSidebar = false

    // 标题提示
    @State private var showTitle = false
    @State private var titleText = ""
    @State private var hideTitleTask: Task<Void, Never>?

    // 开屏幕布
    @State private var showSplash = true
    @State private var splashStatusText = SourceCapability.prefersYangshipinLayout
        ? "正在连接云端服务器..."
        : "正在连接央视网..."
    @State private var splashOffset: CGFloat = 0
    @State private var splashFallbackTask: Task<Void, Never>?

    // 音量/亮度指示器
    @State private var showAdjustIndicator = false
    @State private var adjustIndicatorText = ""
    @State private var hideIndicatorTask: Task<Void, Never>?

    // 手势状态
    @State private var dragMode: DragMode = .none
    @State private var lastDragY: CGFloat = 0
    @State private var touchStartX: CGFloat = 0
    @State private var touchStartY: CGFloat = 0

    // 换台 Toast
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var hideToastTask: Task<Void, Never>?

    // 退出确认
    @State private var lastBackTime: Date = .distantPast
    @State private var showDiagnostics = false
    private let showDebugChrome = DebugSettings.showChrome

    // MARK: - Safe Area Helper
    private var realSafeArea: UIEdgeInsets {
        UIApplication.shared.windows.first?.safeAreaInsets ?? .zero
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Layer 1: WebView
                PlayerWebViewContainer(
                    yangshipinWebView: viewModel.yangshipinWebView,
                    cctvWebView: viewModel.cctvWebView,
                    probeWebView: viewModel.probeWebView,
                    surface: viewModel.visibleSurface,
                    probeRevision: viewModel.probeRevision
                )

                if viewModel.nativePlaybackActive && !viewModel.isCompareMode {
                    NativePlayerView(player: viewModel.nativePlayer.player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                if !viewModel.isCompareMode {
                    gestureLayer(in: geo)
                }

                alwaysAvailableChrome

                // Layer 3: Channel sidebar (left)
                if showChannelSidebar {
                    HStack(spacing: 0) {
                        ChannelListView(
                            channels: viewModel.logicalChannels,
                            currentIndex: viewModel.currentChannelIndex,
                            realSafeAreaLeft: realSafeArea.left,
                            onSelect: { listIndex in
                                let name = viewModel.switchChannel(at: listIndex)
                                closeSidebars()
                                showSplashScreen(statusText: "即将进入：\(name)")
                            },
                            onSelectSource: { listIndex, source in
                                guard viewModel.logicalChannels.indices.contains(listIndex) else { return }
                                let name = viewModel.logicalChannels[listIndex].name
                                let didChange = viewModel.selectSource(source, at: listIndex)
                                closeSidebars()
                                if didChange {
                                    showSplashScreen(statusText: "即将进入：\(name)（\(source.displayName)）")
                                }
                            }
                        )
                        .transition(.move(edge: .leading))
                        Spacer()
                    }
                    .zIndex(20)
                }

                // Layer 4: Program sidebar (right)
                if showProgramSidebar {
                    HStack(spacing: 0) {
                        Spacer()
                        ProgramListView(
                            programs: viewModel.programs,
                            currentIndex: viewModel.currentProgramIndex,
                            realSafeAreaRight: realSafeArea.right,
                            realSafeAreaBottom: realSafeArea.bottom
                        )
                        .transition(.move(edge: .trailing))
                    }
                    .zIndex(20)
                }

                // Layer 5: Adjust indicator (center)
                if showAdjustIndicator {
                    Text(adjustIndicatorText)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.black.opacity(0.7))
                        )
                        .zIndex(50)
                }

                // Layer 6: Title tip (top center)
                if showTitle {
                    VStack {
                        Text(titleText)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.black.opacity(0.7))
                            )
                            .padding(.top, 40)
                        Spacer()
                    }
                    .zIndex(10)
                    .transition(.opacity)
                }

                // Layer 7: Toast message
                if showToast {
                    VStack {
                        Spacer()
                        Text(toastMessage)
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.black.opacity(0.8))
                            )
                            .padding(.bottom, 60)
                    }
                    .zIndex(30)
                    .transition(.opacity)
                }

                if showDiagnostics {
                    DiagnosticPanel(viewModel: viewModel, onClose: { showDiagnostics = false })
                        .zIndex(130)
                }

                if showSplash {
                    SplashView(statusText: splashStatusText)
                        .offset(y: splashOffset)
                        .zIndex(100)
                }
            }
            .background(Color.black)
        }
        .onReceive(viewModel.$currentTitle) { title in
            guard !title.isEmpty else { return }
            showTitleTip(title)
        }
        .onReceive(viewModel.$shouldDismissSplash) { dismiss in
            if dismiss && showSplash {
                animateCurtainRise()
            }
        }
        .onReceive(viewModel.$splashDeadlineExtend) { token in
            guard token > 0, showSplash else { return }
            scheduleSplashFallback()
        }
        .onAppear {
            scheduleSplashFallback()
        }
        .onReceive(viewModel.$playbackMode) { mode in
            if showSplash && splashStatusText.isEmpty
                || splashStatusText == "正在连接云端服务器..."
                || splashStatusText == "正在连接央视网..." {
                splashStatusText = mode == .cctv
                    ? "正在连接央视网..."
                    : "正在连接云端服务器..."
            }
        }
        .onReceive(viewModel.$playbackError) { error in
            guard let error, !error.isEmpty else { return }
            showToastMessage(error)
        }
        .onReceive(viewModel.$isCompareMode) { compare in
            if compare {
                dismissSplashImmediately()
            }
        }
    }

    // MARK: - Gesture Layer
    // Maps from Android: GestureOverlayView.kt

    private func gestureLayer(in geo: GeometryProxy) -> some View {
        Color.clear
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDragChanged(value: value, in: geo)
                    }
                    .onEnded { value in
                        handleDragEnded(value: value, in: geo)
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        viewModel.togglePlayPause()
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 1)
                    .onEnded {
                        if isMenuVisible {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                closeSidebars()
                            }
                        }
                    }
            )
            .zIndex(15)
            .allowsHitTesting(!viewModel.isCompareMode && (!isMenuVisible || !isTouchInSidebar))
    }

    private var alwaysAvailableChrome: some View {
        VStack {
            HStack(spacing: 8) {
                if viewModel.isCompareMode {
                    chromeButton("退出对照") {
                        viewModel.exitOfficialCompare()
                    }
                }
                Spacer()
                if showDebugChrome {
                    chromeButton("频道") {
                        dismissSplashImmediately()
                        showChannelSidebar = true
                        showProgramSidebar = false
                        showDiagnostics = false
                    }
                    chromeButton("节目") {
                        dismissSplashImmediately()
                        showProgramSidebar = true
                        showChannelSidebar = false
                        showDiagnostics = false
                    }
                    chromeButton("诊断") {
                        dismissSplashImmediately()
                        showDiagnostics = true
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            Spacer()
        }
        .zIndex(140)
        .allowsHitTesting(showDebugChrome || viewModel.isCompareMode)
    }

    private func chromeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var isMenuVisible: Bool {
        showChannelSidebar || showProgramSidebar
    }

    // 简化处理：当侧边栏打开时让手势层仍接收事件
    // 但在侧边栏区域内不拦截（通过 allowsHitTesting）
    private var isTouchInSidebar: Bool {
        false // SwiftUI 的 sidebar 本身可接收触摸
    }

    // MARK: - Drag State Machine
    // Maps from Android: GestureOverlayView.kt DragMode

    private func handleDragChanged(value: DragGesture.Value, in geo: GeometryProxy) {
        let currentX = value.location.x
        let currentY = value.location.y

        if dragMode == .none {
            // ACTION_DOWN
            touchStartX = value.startLocation.x
            touchStartY = value.startLocation.y
            lastDragY = value.startLocation.y
            dragMode = .undecided
            if touchStartX > geo.size.width * 0.6 {
                SystemVolume.shared.prepare()
            }
        }

        if dragMode == .undecided {
            let dx = abs(currentX - touchStartX)
            let dy = abs(currentY - touchStartY)
            let threshold: CGFloat = 30

            if dx > threshold || dy > threshold {
                if dy > dx * 1.2 {
                    // 纵向拖拽 → 按起始横坐标分区
                    let screenWidth = geo.size.width
                    let zoneLeftEnd: CGFloat = 0.4
                    let zoneRightStart: CGFloat = 0.6

                    if touchStartX < screenWidth * zoneLeftEnd {
                        dragMode = .brightness
                        adjustIndicatorText = "☀ \(Int((SessionBrightness.shared.current * 100).rounded()))%"
                        showAdjustIndicator = true
                    } else if touchStartX > screenWidth * zoneRightStart {
                        dragMode = .volume
                        let start = SystemVolume.shared.beginGesture()
                        adjustIndicatorText = "🔊 \(Int((start * 100).rounded()))%"
                        showAdjustIndicator = true
                    } else {
                        dragMode = .gesture
                    }
                } else {
                    dragMode = .gesture
                }
            }
        }

        // 正在调节亮度/音量
        if dragMode == .brightness {
            let deltaY = lastDragY - currentY
            lastDragY = currentY
            let sensitivity: CGFloat = 1.5
            let deltaPercent = (deltaY / geo.size.height) * sensitivity
            adjustBrightness(deltaPercent)
        } else if dragMode == .volume {
            let deltaY = lastDragY - currentY
            lastDragY = currentY
            let sensitivity: CGFloat = 1.5
            let deltaPercent = (deltaY / geo.size.height) * sensitivity
            adjustVolume(deltaPercent)
        }
    }

    private func handleDragEnded(value: DragGesture.Value, in geo: GeometryProxy) {
        let wasAdjusting = (dragMode == .brightness || dragMode == .volume)

        if wasAdjusting {
            if dragMode == .volume {
                SystemVolume.shared.endGesture()
                viewModel.resumeCctvIfPausedAfterVolume()
            }
            // 松手后 1.5 秒自动隐藏
            hideIndicatorTask?.cancel()
            hideIndicatorTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled {
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showAdjustIndicator = false
                        }
                    }
                }
            }
            dragMode = .none
            return
        }

        // 处理 fling/swipe 手势
        if dragMode == .gesture || dragMode == .undecided {
            let dx = value.translation.width
            let dy = value.translation.height
            let absDx = abs(dx)
            let absDy = abs(dy)
            
            // 降低阈值，使划动更灵敏
            let swipeThreshold: CGFloat = 50
            let velocityThreshold: CGFloat = 100
            let velocity = value.predictedEndTranslation

            // 水平滑动优先
            if absDx > absDy && absDx > swipeThreshold && abs(velocity.width) > velocityThreshold {
                withAnimation(.easeInOut(duration: 0.25)) {
                    if dx > 0 {
                        onSwipeRight()
                    } else {
                        onSwipeLeft()
                    }
                }
            }
            // 垂直滑动（中央区域换台）
            else if absDy > absDx && absDy > swipeThreshold && abs(velocity.height) > velocityThreshold {
                if dy > 0 {
                    onSwipeDown()
                } else {
                    onSwipeUp()
                }
            }
        }

        dragMode = .none
    }

    // MARK: - Gesture Actions
    // Maps from Android: MainActivity.kt gesture callbacks

    private func onSwipeUp() {
        // 上滑 = 下一个频道
        let result = viewModel.quickSwitchChannel(isNext: true)
        if !result.allowed {
            showToastMessage("高频次换台会导致播放卡顿\n等待3s方可继续换台~")
            return
        }
        if let name = result.channelName {
            showSplashScreen(statusText: "即将进入：\(name)")
        }
    }

    private func onSwipeDown() {
        // 下滑 = 上一个频道
        let result = viewModel.quickSwitchChannel(isNext: false)
        if !result.allowed {
            showToastMessage("高频次换台会导致播放卡顿\n等待3s方可继续换台~")
            return
        }
        if let name = result.channelName {
            showSplashScreen(statusText: "即将进入：\(name)")
        }
    }

    private func onSwipeLeft() {
        // 左滑 → 呼出节目单（屏幕右侧面板）
        showProgramSidebar = true
        showChannelSidebar = false
    }

    private func onSwipeRight() {
        // 右滑 → 呼出频道列表（屏幕左侧面板）
        showChannelSidebar = true
        showProgramSidebar = false
    }

    // MARK: - Volume & Brightness

    private func adjustVolume(_ deltaPercent: CGFloat) {
        let next = SystemVolume.shared.adjust(by: Float(deltaPercent))
        adjustIndicatorText = "🔊 \(Int((next * 100).rounded()))%"
    }

    private func adjustBrightness(_ deltaPercent: CGFloat) {
        let next = SessionBrightness.shared.adjust(by: deltaPercent)
        adjustIndicatorText = "☀ \(Int((next * 100).rounded()))%"
    }

    // MARK: - Splash Screen
    // Maps from Android: MainActivity.kt showSplashScreen, animateCurtainRise

    private func dismissSplashImmediately() {
        splashFallbackTask?.cancel()
        showSplash = false
        splashOffset = 0
    }

    private func showSplashScreen(statusText: String) {
        viewModel.resetSplash()
        splashStatusText = statusText
        splashOffset = 0
        showSplash = true
        scheduleSplashFallback()
    }

    private func scheduleSplashFallback() {
        splashFallbackTask?.cancel()
        let started = Date()
        splashFallbackTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let shouldRise = await MainActor.run { () -> Bool in
                    guard showSplash else { return false }
                    let elapsed = Date().timeIntervalSince(started)
                    let limit: TimeInterval = viewModel.nativePlaybackActive ? 36 : 10
                    return elapsed >= limit
                }
                if shouldRise {
                    await MainActor.run {
                        if showSplash {
                            animateCurtainRise()
                        }
                    }
                    return
                }
                let finished = await MainActor.run { !showSplash }
                if finished { return }
            }
        }
    }

    private func animateCurtainRise() {
        splashFallbackTask?.cancel()
        let screenHeight = UIScreen.main.bounds.height
        withAnimation(.easeInOut(duration: 0.8)) {
            splashOffset = -screenHeight
        }
        // 动画结束后隐藏
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            showSplash = false
            splashOffset = 0
        }
    }

    // MARK: - Title Tip

    private func showTitleTip(_ title: String) {
        titleText = title
        withAnimation { showTitle = true }
        hideTitleTask?.cancel()
        hideTitleTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    withAnimation { showTitle = false }
                }
            }
        }
    }

    // MARK: - Toast

    private func showToastMessage(_ msg: String) {
        toastMessage = msg
        withAnimation { showToast = true }
        hideToastTask?.cancel()
        hideToastTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    withAnimation { showToast = false }
                }
            }
        }
    }

    // MARK: - Sidebar Control

    private func closeSidebars() {
        showChannelSidebar = false
        showProgramSidebar = false
    }
}

// MARK: - Drag Mode Enum
// Maps from Android: GestureOverlayView.kt DragMode

enum DragMode {
    case none
    case undecided
    case brightness
    case volume
    case gesture
}

struct DiagnosticPanel: View {
    @ObservedObject var viewModel: WebViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("播放诊断")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button("关闭", action: onClose)
                    .foregroundColor(.white)
            }

            Text("build \(PlaybackDiagnostics.buildID) · 不是完整网络抓包")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "BBBBBB"))

            Text(viewModel.diagnostics.lastSummary)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .lineLimit(3)

            Text("下方开关只记录配置；再次点「官方页面对照」后才会应用。")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "BBBBBB"))

            Toggle("对照使用 Safari UA", isOn: $viewModel.probeUseSafariUA)
                .foregroundColor(.white)
                .onChange(of: viewModel.probeUseSafariUA) { _ in
                    viewModel.noteProbeConfigurationChanged()
                }
            Toggle("对照允许页内播放", isOn: $viewModel.probeAllowsInlinePlayback)
                .foregroundColor(.white)
                .onChange(of: viewModel.probeAllowsInlinePlayback) { _ in
                    viewModel.noteProbeConfigurationChanged()
                }

            HStack(spacing: 8) {
                Button("官方页面对照") {
                    viewModel.enterOfficialCompare()
                    onClose()
                }
                Button("复制日志") {
                    viewModel.copyDiagnostics()
                }
                Button("导出") {
                    viewModel.shareDiagnostics()
                }
                Button("清空") {
                    viewModel.diagnostics.clearAll()
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(Color(hex: "00A1D6"))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(viewModel.diagnostics.events.suffix(40).reversed())) { event in
                        Text("#\(event.attempt) [\(event.category)] \(event.message)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.86))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 520, maxHeight: 360, alignment: .topLeading)
        .background(Color.black.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.trailing, 16)
        .padding(.top, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

// MARK: - Splash View
// Maps from Android: fl_splash_cover in activity_main.xml

struct SplashView: View {
    let statusText: String

    // 呼吸灯动画
    @State private var breathingAlpha: Double = 0.4

    // 加载点动画
    @State private var dotAlphas: [Double] = [0.3, 0.3, 0.3]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 黑色底
                Color.black

                // 魅影紫呼吸灯
                // Maps from: bg_breathing_light.xml — radial gradient #FF0055 → #4A148C → #000000
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color(hex: "FF0055"),
                        Color(hex: "4A148C"),
                        Color.black
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: 500
                )
                .opacity(breathingAlpha)

                // 磨砂覆盖层
                // Maps from: bg_frosted_overlay.xml — #B3000000
                Color.black.opacity(0.7)

                // 中央内容
                VStack(spacing: 0) {
                    Spacer()

                    // 标题
                    Text("LiteWebTV")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.white)
                        .tracking(4)
                        .shadow(color: .black.opacity(0.5), radius: 10, x: 2, y: 2)

                    // 分隔线
                    Rectangle()
                        .fill(Color(hex: "00A1D6"))
                        .frame(width: 60, height: 2)
                        .padding(.vertical, 20)

                    // 状态文字
                    Text(statusText)
                        .font(.system(size: 18))
                        .foregroundColor(Color(hex: "DDDDDD"))
                        .shadow(color: .black.opacity(0.5), radius: 5, x: 1, y: 1)

                    // 三点加载动画
                    HStack(spacing: 16) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(Color(hex: "00A1D6"))
                                .frame(width: 10, height: 10)
                                .opacity(dotAlphas[index])
                        }
                    }
                    .padding(.top, 24)

                    Spacer()

                    // 底部声明
                    VStack(spacing: 8) {
                        Text("基于 YukonKong/LiteWebTV 重新实现的 iOS 版本")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.8))
                        
                        Text("本项目为免费的开源软件，遵循 CC BY-SA 4.0 协议")
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.5))
                            .padding(.bottom, 4)

                        // iOS 仓库链接
                        HStack(spacing: 4) {
                            Image(systemName: "swift")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "00A1D6"))
                            Text("GitHub: KremeCN/LiteWebTV-iOS")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "BBBBBB"))
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .edgesIgnoringSafeArea(.all)
        }
        .onAppear {
            startBreathingAnimation()
            startDotAnimation()
        }
    }

    /// 呼吸灯动画：0.4 ↔ 1.0，2 秒周期
    private func startBreathingAnimation() {
        withAnimation(
            .easeInOut(duration: 2.0)
            .repeatForever(autoreverses: true)
        ) {
            breathingAlpha = 1.0
        }
    }

    /// 三点波浪动画：各点错峰 200ms
    private func startDotAnimation() {
        for i in 0..<3 {
            let delay = Double(i) * 0.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(
                    .easeInOut(duration: 0.6)
                    .repeatForever(autoreverses: true)
                ) {
                    dotAlphas[i] = 1.0
                }
            }
        }
    }
}

// MARK: - Color Extension (Hex Support)

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: // RGB
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
