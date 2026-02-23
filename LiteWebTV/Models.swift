import Foundation

/// 频道数据模型
/// Maps from Android: TvModels.kt → ChannelItem
struct ChannelItem: Codable, Identifiable {
    let index: Int       // DOM 索引，用于点击切换
    let name: String     // 频道名称
    let isActive: Bool   // 是否是当前频道

    var id: Int { index }
}

/// 节目单数据模型
/// Maps from Android: TvModels.kt → ProgramItem
struct ProgramItem: Codable, Identifiable {
    let time: String       // 播出时间
    let title: String      // 节目名称
    let isCurrent: Bool    // 是否正在播出

    var id: String { "\(time)-\(title)" }
    
    // 双时区显示：如果当前系统不在东八区，则格式化为 "北京时间 (本地时间)"
    var displayTime: String {
        let beijingTZ = TimeZone(identifier: "Asia/Shanghai")!
        let localTZ = LiteWebTVApp.realLocalTimeZone
        
        if beijingTZ.secondsFromGMT() == localTZ.secondsFromGMT() {
            return time
        }
        
        // 提取时分并根据时差换算
        let parts = time.split(separator: ":")
        if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) {
            // 获取当前时间戳在两个时区下分别的 UTC 偏移量（按秒计）
            // 我们不能用 Date() 和 Calendar.current 进行格式化换算，因为整个 App 的时区已经被我们全局污染为东八区了
            let now = Date()
            let beijingOffset = beijingTZ.secondsFromGMT(for: now)
            let localOffset = localTZ.secondsFromGMT(for: now)
            
            // 计算东八区和当前物理真实时区的【分钟差】
            let diffMinutes = (localOffset - beijingOffset) / 60
            
            // 严谨计算目标时间，处理跨天、负数绕回
            // 比如 22:00 减去 6小时（UTC+2） = 16:00
            // 比如 02:00 减去 6小时 = -04:00 + 24小时 = 20:00 (前一天)
            var targetTotalMinutes = (h * 60 + m) + diffMinutes
            targetTotalMinutes = (targetTotalMinutes % 1440 + 1440) % 1440
            
            let localH = targetTotalMinutes / 60
            let localM = targetTotalMinutes % 60
            let localTimeStr = String(format: "%02d:%02d", localH, localM)
            
            return "\(time) (\(localTimeStr))"
        }
        return time
    }
}
