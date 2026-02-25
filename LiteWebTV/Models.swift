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
    var isCurrent: Bool    // 是否正在播出

    var id: String { "\(time)-\(title)" }
    
    var displayTime: String {
        let beijingTZ = TimeZone(identifier: "Asia/Shanghai")!
        let localTZ = LiteWebTVApp.realLocalTimeZone

        let parts = time.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              h >= 0, h <= 23,
              m >= 0, m <= 59 else {
            return time
        }

        let now = Date()
        var beijingCalendar = Calendar(identifier: .gregorian)
        beijingCalendar.timeZone = beijingTZ

        let dateParts = beijingCalendar.dateComponents([.year, .month, .day], from: now)
        guard let y = dateParts.year,
              let mo = dateParts.month,
              let d = dateParts.day else {
            return time
        }

        var fullParts = DateComponents()
        fullParts.year = y
        fullParts.month = mo
        fullParts.day = d
        fullParts.hour = h
        fullParts.minute = m
        fullParts.second = 0

        guard let beijingDate = beijingCalendar.date(from: fullParts) else {
            return time
        }

        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = localTZ

        let beijingDay = beijingCalendar.component(.day, from: beijingDate)
        let localDay = localCalendar.component(.day, from: beijingDate)

        let beijingTime = String(format: "%02d:%02d", h, m)
        let localTime = String(
            format: "%02d:%02d",
            localCalendar.component(.hour, from: beijingDate),
            localCalendar.component(.minute, from: beijingDate)
        )

        if beijingTZ.secondsFromGMT(for: now) == localTZ.secondsFromGMT(for: now) {
            return beijingTime
        }

        if beijingDay == localDay {
            return "\(beijingTime)（\(localTime)）"
        }

        return "\(beijingDay)日 \(beijingTime)（\(localDay)日 \(localTime)）"
    }
}
