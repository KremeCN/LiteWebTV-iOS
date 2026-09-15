import Foundation

/// 播放源
enum StreamSource: String, Codable, CaseIterable {
    case yangshipin
    case cctv

    var displayName: String {
        switch self {
        case .yangshipin: return "央视频"
        case .cctv: return "央视网"
        }
    }
}

/// 逻辑频道（UI 与换台使用，合并央视频 / 央视网）
struct LogicalChannel: Identifiable {
    let id: String
    let name: String
    let group: String?
    let yangshipinDomIndex: Int?
    let cctvSlug: String?
    let availableSources: [StreamSource]
    var selectedSource: StreamSource
    var isActive: Bool

    var canSwitchSource: Bool {
        availableSources.count > 1
    }
}

/// 频道数据模型（央视频 JS 桥接）
/// Maps from Android: TvModels.kt → ChannelItem
struct ChannelItem: Codable, Identifiable {
    let index: Int
    let name: String
    let isActive: Bool

    var id: Int { index }
}

/// 节目单数据模型
/// Maps from Android: TvModels.kt → ProgramItem
struct ProgramItem: Codable, Identifiable {
    let time: String
    let title: String
    var isCurrent: Bool

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
