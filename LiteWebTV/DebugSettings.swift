import Foundation

/// 本地调试开关。不进入设置页；改常量后重新编译即可。
enum DebugSettings {
    /// 右上角「频道 / 节目 / 诊断」按钮。
    static let showChrome = false

    enum SourceLayout: String {
        /// 按系统能力：iOS 17.2+ 且探测到 MSE 时双源，否则央视网单源。
        case followSystem
        /// 强制高版本布局：显示央视频频道，重叠台提供双源。
        case dualSource
        /// 强制低版本布局：只显示央视网单源，并隐藏其不可用频道。
        case cctvOnly
    }

    /// 频道源布局。正式使用保持 `.followSystem`。
    static let sourceLayout: SourceLayout = .followSystem
}
