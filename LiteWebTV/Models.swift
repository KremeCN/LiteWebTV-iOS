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
            let offsetSeconds = localTZ.secondsFromGMT() - beijingTZ.secondsFromGMT()
            
            var totalMinutes = h * 60 + m + (offsetSeconds / 60)
            totalMinutes = (totalMinutes % 1440 + 1440) % 1440 // 处理跨天绕回
            
            let localH = totalMinutes / 60
            let localM = totalMinutes % 60
            let localTimeStr = String(format: "%02d:%02d", localH, localM)
            
            return "\(time) (\(localTimeStr))"
        }
        return time
    }
}
