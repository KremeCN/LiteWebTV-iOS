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
            // 使用当前日期构建一个完整的北京时间 Date
            var calendar = Calendar.current
            calendar.timeZone = beijingTZ
            
            let now = Date()
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = h
            components.minute = m
            components.second = 0
            
            if let beijingDate = calendar.date(from: components) {
                // 将这个具体的 Date 转换回设备的本地时区进行格式化
                let formatter = DateFormatter()
                formatter.timeZone = localTZ
                formatter.dateFormat = "HH:mm"
                let localTimeStr = formatter.string(from: beijingDate)
                
                return "\(time) (\(localTimeStr))"
            }
        }
        return time
    }
}
