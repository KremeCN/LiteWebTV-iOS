import Foundation

/// 记住每个逻辑频道上次选择的播放源
enum SourcePreferenceStore {
    private static let key = "channel_source_preferences"

    static func preferredSource(for channelId: String) -> StreamSource? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String],
              let raw = dict[channelId],
              let source = StreamSource(rawValue: raw) else {
            return nil
        }
        return source
    }

    static func save(channelId: String, source: StreamSource) {
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        dict[channelId] = source.rawValue
        UserDefaults.standard.set(dict, forKey: key)
    }

    private static let lastChannelKey = "last_logical_channel_id"

    static var lastChannelId: String? {
        get { UserDefaults.standard.string(forKey: lastChannelKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastChannelKey) }
    }
}
