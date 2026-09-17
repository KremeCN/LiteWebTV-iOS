import Foundation

/// 央视网源优先走原生 CDN + H5E。地址表对齐 NativeWasmTv `ChannelCatalog.streamUrl()`。
enum CctvNativeCatalog {
    private static let bitrateRange = "?b=200-4000"
    private static let defaultBase = "https://ldocctvwbcdbyte.volcfcdn.com/ldocctvwbcd/"
    private static let webpageBlockedSlugs: Set<String> = ["cctv3", "cctv6", "cctv8"]

    static func supports(_ slug: String) -> Bool {
        CCTVCatalog.entry(for: slug) != nil
    }

    /// 3/6/8 手机页会踢到央视频空页，CDN 失败也不能回 `/m/`。
    static func allowsWebpageFallback(_ slug: String) -> Bool {
        supports(slug) && !webpageBlockedSlugs.contains(slug)
    }

    static func masterURL(for slug: String) -> URL? {
        guard supports(slug) else { return nil }
        return URL(string: streamURLString(for: slug))
    }

    static func pageHost() -> URL {
        URL(string: "https://tv.cctv.com/")!
    }

    static func referer(for slug: String) -> URL {
        URL(string: "https://tv.cctv.com/live/\(slug)/")!
    }

    private static func streamURLString(for slug: String) -> String {
        switch slug {
        case "cctv1":
            return "https://ldncctvwbcdcnc.v.wscdns.com/ldncctvwbcd/cdrmldcctv1_1/index.m3u8" + bitrateRange
        case "cctv3":
            return "https://ldocctvwbcdks.v.kcdnvip.com/ldocctvwbcd/cdrmldcctv3_1/index.m3u8" + bitrateRange
        case "cctv5":
            return "https://ldcctvwbcdks.v.kcdnvip.com/ldcctvwbcd/cdrmldcctv5_1/index.m3u8" + bitrateRange
        case "cctv5plus":
            return "https://ldcctvwbcdtxy.liveplay.myqcloud.com/ldcctvwbcd/cdrmldcctv5plus_1/index.m3u8" + bitrateRange
        case "cctv6":
            return "https://ldocctvwbcdbd.a.bdydns.com/ldocctvwbcd/cdrmldcctv6_1/index.m3u8" + bitrateRange
        case "cctv8":
            return "https://ldocctvwbcdks.v.kcdnvip.com/ldocctvwbcd/cdrmldcctv8_1/index.m3u8" + bitrateRange
        case "cctv13":
            return "https://ldncctvwbcdbd.a.bdydns.com/ldncctvwbcd/cdrmldcctv13_1/index.m3u8" + bitrateRange
        case "cctv16":
            return "https://ldcctvwbcdks.v.kcdnvip.com/ldcctvwbcd/cdrmldcctv16_1/index.m3u8" + bitrateRange
        default:
            return defaultBase + "cdrmld" + slug + "_1/index.m3u8" + bitrateRange
        }
    }
}
