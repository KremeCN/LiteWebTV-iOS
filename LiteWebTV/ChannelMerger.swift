import Foundation

/// 将央视频刮取的频道与央视网目录合并为逻辑频道表
enum ChannelMerger {
    static func cctvOnlyChannels(activeIndex: Int = 0) -> [LogicalChannel] {
        CCTVCatalog.channels.enumerated().map { offset, entry in
            LogicalChannel(
                id: entry.slug,
                name: entry.name,
                group: nil,
                yangshipinDomIndex: nil,
                cctvSlug: entry.slug,
                availableSources: [.cctv],
                selectedSource: .cctv,
                isActive: offset == activeIndex
            )
        }
    }

    static func merge(yangshipinItems: [ChannelItem]) -> [LogicalChannel] {
        var result: [LogicalChannel] = []
        var usedSlugs = Set<String>()

        for item in yangshipinItems {
            let slug = CCTVCatalog.slug(matchingYangshipinName: item.name)
            var sources: [StreamSource] = [.yangshipin]
            if let slug {
                sources.append(.cctv)
                usedSlugs.insert(slug)
            }

            let channelId = slug ?? "ysp-\(item.index)"
            let selected = resolveSelectedSource(
                channelId: channelId,
                available: sources,
                defaultSource: .yangshipin
            )

            result.append(
                LogicalChannel(
                    id: channelId,
                    name: item.name,
                    group: nil,
                    yangshipinDomIndex: item.index,
                    cctvSlug: slug,
                    availableSources: sources,
                    selectedSource: selected,
                    isActive: item.isActive
                )
            )
        }

        for entry in CCTVCatalog.channels where !usedSlugs.contains(entry.slug) {
            let group = (entry.slug == "cctveurope" || entry.slug == "cctvamerica") ? "国际" : "央视网"
            result.append(
                LogicalChannel(
                    id: entry.slug,
                    name: entry.name,
                    group: group,
                    yangshipinDomIndex: nil,
                    cctvSlug: entry.slug,
                    availableSources: [.cctv],
                    selectedSource: .cctv,
                    isActive: false
                )
            )
        }

        return result
    }

    private static func resolveSelectedSource(
        channelId: String,
        available: [StreamSource],
        defaultSource: StreamSource
    ) -> StreamSource {
        if let saved = SourcePreferenceStore.preferredSource(for: channelId),
           available.contains(saved) {
            return saved
        }
        if available.contains(defaultSource) {
            return defaultSource
        }
        return available.first ?? defaultSource
    }
}
