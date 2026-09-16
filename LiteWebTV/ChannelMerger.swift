import Foundation

/// 将央视频刮取的频道与央视网目录合并为逻辑频道表
enum ChannelMerger {
    private static let cctv4FamilySlugs: [String] = ["cctveurope", "cctvamerica"]

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
        var relocatedCctv4: [String: LogicalChannel] = [:]

        for item in yangshipinItems {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            let matchedSlug = CCTVCatalog.slug(matchingYangshipinName: name)
            let slug = matchedSlug.flatMap { usedSlugs.contains($0) ? nil : $0 }
            if let slug {
                usedSlugs.insert(slug)
            }

            // Stable channel identity does not imply a playable CCTV mobile source.
            let cctvEntry = slug.flatMap { CCTVCatalog.entry(for: $0) }
            var sources: [StreamSource] = [.yangshipin]
            if cctvEntry != nil {
                sources.append(.cctv)
            }

            let channelId = slug ?? "ysp-\(item.index)"
            let displayName = slug.flatMap { CCTVCatalog.entry(for: $0)?.name } ?? name
            let channel = LogicalChannel(
                id: channelId,
                name: displayName,
                group: nil,
                yangshipinDomIndex: item.index,
                cctvSlug: cctvEntry?.slug,
                availableSources: sources,
                selectedSource: resolveSelectedSource(
                    channelId: channelId,
                    available: sources,
                    defaultSource: .yangshipin
                ),
                isActive: item.isActive
            )

            if let slug, cctv4FamilySlugs.contains(slug) {
                relocatedCctv4[slug] = channel
                continue
            }

            result.append(channel)
        }

        for slug in cctv4FamilySlugs where relocatedCctv4[slug] == nil && !usedSlugs.contains(slug) {
            guard let entry = CCTVCatalog.entry(for: slug) else { continue }
            usedSlugs.insert(slug)
            relocatedCctv4[slug] = catalogOnlyChannel(entry)
        }

        insertCctv4Family(relocatedCctv4, into: &result)

        for entry in CCTVCatalog.channels where !usedSlugs.contains(entry.slug) {
            result.append(catalogOnlyChannel(entry))
        }

        return result
    }

    private static func catalogOnlyChannel(_ entry: CCTVCatalog.Entry) -> LogicalChannel {
        LogicalChannel(
            id: entry.slug,
            name: entry.name,
            group: nil,
            yangshipinDomIndex: nil,
            cctvSlug: entry.slug,
            availableSources: [.cctv],
            selectedSource: .cctv,
            isActive: false
        )
    }

    private static func insertCctv4Family(
        _ relocated: [String: LogicalChannel],
        into result: inout [LogicalChannel]
    ) {
        let extras = cctv4FamilySlugs.compactMap { relocated[$0] }
        guard !extras.isEmpty else { return }

        if let asiaIndex = result.firstIndex(where: { $0.cctvSlug == "cctv4" }) {
            result.insert(contentsOf: extras, at: asiaIndex + 1)
        } else {
            result.insert(contentsOf: extras, at: 0)
        }
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
