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
        return time
    }
}
