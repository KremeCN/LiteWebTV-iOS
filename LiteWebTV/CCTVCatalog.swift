import Foundation

/// 央视网直播频道目录（与 tv.cctv.com/live 右侧列表对齐）
enum CCTVCatalog {
    struct Entry: Identifiable {
        let slug: String
        let name: String

        var id: String { slug }
        var epgId: String { slug }
    }

    static let channels: [Entry] = [
        Entry(slug: "cctv1", name: "CCTV-1 综合"),
        Entry(slug: "cctv2", name: "CCTV-2 财经"),
        Entry(slug: "cctv3", name: "CCTV-3 综艺"),
        Entry(slug: "cctv4", name: "CCTV-4 中文国际（亚）"),
        Entry(slug: "cctveurope", name: "CCTV-4 中文国际（欧）"),
        Entry(slug: "cctvamerica", name: "CCTV-4 中文国际（美）"),
        Entry(slug: "cctv5", name: "CCTV-5 体育"),
        Entry(slug: "cctv5plus", name: "CCTV-5+ 体育赛事"),
        Entry(slug: "cctv6", name: "CCTV-6 电影"),
        Entry(slug: "cctv7", name: "CCTV-7 国防军事"),
        Entry(slug: "cctv8", name: "CCTV-8 电视剧"),
        Entry(slug: "cctvjilu", name: "CCTV-9 纪录"),
        Entry(slug: "cctv10", name: "CCTV-10 科教"),
        Entry(slug: "cctv11", name: "CCTV-11 戏曲"),
        Entry(slug: "cctv12", name: "CCTV-12 社会与法"),
        Entry(slug: "cctv13", name: "CCTV-13 新闻"),
        Entry(slug: "cctvchild", name: "CCTV-14 少儿"),
        Entry(slug: "cctv15", name: "CCTV-15 音乐"),
        Entry(slug: "cctv16", name: "CCTV-16 奥林匹克"),
        Entry(slug: "cctv17", name: "CCTV-17 农业农村"),
    ]

    static func entry(for slug: String) -> Entry? {
        channels.first { $0.slug == slug }
    }

    /// 桌面直播页优先。手机页在 iOS 上会因 hls.js/wasm 判定失败弹出
    /// 「本时段节目请使用电脑端或央视影音客户端观看」。
    static func pageURLs(for slug: String) -> [URL] {
        var urls = [desktopURL(slug)]
        if slug == "cctveurope" || slug == "cctvamerica" {
            urls.append(URL(string: "https://tv.cctv.com/live/\(slug)/index.shtml")!)
        }
        urls.append(mobileURL(slug))
        return urls
    }

    static func epgURL(for slug: String, date: Date = Date()) -> URL? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        let dateString = String(format: "%04d%02d%02d", year, month, day)
        let raw = "https://api.cntv.cn/epg/getEpgInfoByChannelNew?c=\(slug)&serviceId=tvcctv&d=\(dateString)"
        return URL(string: raw)
    }

    /// 从央视频频道名推断央视网 slug，用于合并重叠频道
    static func slug(matchingYangshipinName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed
            .replacingOccurrences(of: "＋", with: "+")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "－", with: "-")
            .uppercased()

        // CGTN（含外语纪录）不是央视网直播页
        if normalized.contains("CGTN") {
            return nil
        }

        if normalized.contains("5+") || normalized.contains("CCTV5+") {
            return "cctv5plus"
        }

        guard let match = normalized.range(of: #"CCTV-?(\d{1,2})"#, options: .regularExpression) else {
            return nil
        }

        let token = String(normalized[match])
        let digits = token.replacingOccurrences(of: "CCTV", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard let number = Int(digits), (1...17).contains(number) else {
            return nil
        }

        switch number {
        case 4:
            if normalized.contains("欧") { return "cctveurope" }
            if normalized.contains("美") { return "cctvamerica" }
            return "cctv4"
        case 5:
            return normalized.contains("+") ? "cctv5plus" : "cctv5"
        case 9:
            return "cctvjilu"
        case 14:
            return "cctvchild"
        default:
            return "cctv\(number)"
        }
    }

    private static func desktopURL(_ slug: String) -> URL {
        URL(string: "https://tv.cctv.com/live/\(slug)/")!
    }

    private static func mobileURL(_ slug: String) -> URL {
        URL(string: "https://tv.cctv.com/live/\(slug)/m/")!
    }
}

// MARK: - EPG API Models

struct CCTVEPGResponse: Decodable {
    let data: [String: CCTVEPGChannel]?
}

struct CCTVEPGChannel: Decodable {
    let isLive: String?
    let channelName: String?
    let list: [CCTVEPGEntry]?
}

struct CCTVEPGEntry: Decodable {
    let title: String
    let showTime: String
    let startTime: Int
    let endTime: Int
}
