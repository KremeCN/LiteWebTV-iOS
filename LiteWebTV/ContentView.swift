import SwiftUI
import WebKit

// MARK: - WKWebView UIViewRepresentable Wrapper

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView.backgroundColor = .black
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
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
    @State private var splashStatusText = "正在连接云端服务器..."
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

    // 亮度
    @State private var currentBrightness: CGFloat = UIScreen.main.brightness

    // 换台 Toast
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var hideToastTask: Task<Void, Never>?

    // 退出确认
    @State private var lastBackTime: Date = .distantPast

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Layer 1: WebView
                WebViewContainer(webView: viewModel.webView)

                // Layer 2: Gesture detection overlay
                gestureLayer(in: geo)

                // Layer 3: Channel sidebar (left)
                if showChannelSidebar {
                    HStack(spacing: 0) {
                        ChannelListView(
                            channels: viewModel.channels,
                            currentIndex: viewModel.currentChannelIndex,
                            onSelect: { item in
                                let name = viewModel.switchChannel(item)
                                closeSidebars()
                                showSplashScreen(statusText: "即将进入：\(name)")
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
                            currentIndex: viewModel.currentProgramIndex
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

                // Layer 8: Splash cover (highest z-index)
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
        .onAppear {
            // 10 秒兜底：如果 JS 信号未到达，强制升起幕布
            splashFallbackTask = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if !Task.isCancelled {
                    await MainActor.run {
                        if showSplash {
                            animateCurtainRise()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Gesture Layer
    // Maps from Android: GestureOverlayView.kt

    private func gestureLayer(in geo: GeometryProxy) -> some View {
        Color.clear
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
            .allowsHitTesting(!isMenuVisible || !isTouchInSidebar)
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
                        adjustIndicatorText = "☀ \(Int(currentBrightness * 100))%"
                        showAdjustIndicator = true
                    } else if touchStartX > screenWidth * zoneRightStart {
                        dragMode = .volume
                        adjustIndicatorText = "🔊 \(currentVolumePercent)%"
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

    private var currentVolumePercent: Int {
        // iOS 不允许直接读取系统音量，使用估算值
        50
    }

    private func adjustVolume(_ deltaPercent: CGFloat) {
        // iOS 系统音量通过 MPVolumeView 控制
        // 简化实现：通过 JS 控制页面内 video 元素音量
        let js = """
        (function(){
            var video = document.querySelector('video');
            if(video){
                video.volume = Math.min(1.0, Math.max(0.0, video.volume + \(deltaPercent)));
                return Math.round(video.volume * 100);
            }
            return -1;
        })();
        """
        viewModel.webView.evaluateJavaScript(js) { result, _ in
            if let percent = result as? Int, percent >= 0 {
                DispatchQueue.main.async {
                    adjustIndicatorText = "🔊 \(percent)%"
                }
            }
        }
    }

    private func adjustBrightness(_ deltaPercent: CGFloat) {
        currentBrightness = max(0.01, min(1.0, currentBrightness + deltaPercent))
        UIScreen.main.brightness = currentBrightness
        adjustIndicatorText = "☀ \(Int(currentBrightness * 100))%"
    }

    // MARK: - Splash Screen
    // Maps from Android: MainActivity.kt showSplashScreen, animateCurtainRise

    private func showSplashScreen(statusText: String) {
        viewModel.resetSplash()
        splashStatusText = statusText
        splashOffset = 0
        showSplash = true

        // 10 秒兜底
        splashFallbackTask?.cancel()
        splashFallbackTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    if showSplash {
                        animateCurtainRise()
                    }
                }
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
                        Text("！开源共享，禁止买卖！")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(Color(hex: "FF5252"))
                            .shadow(color: .black.opacity(0.5), radius: 3, x: 1, y: 1)

                        Text("https://github.com/YukonKong/LiteWebTV")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "BBBBBB"))

                        Text("https://gitee.com/YukonKong/LiteWebTV")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "BBBBBB"))
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
