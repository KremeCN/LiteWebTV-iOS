import Foundation

enum CctvHlsRewriter {
    struct StreamVariant: Equatable {
        let bandwidth: Int
        let resolution: String
        let uri: URL

        var qualityLabel: String {
            CctvHlsRewriter.qualityLabel(in: uri.path, resolution: resolution)
        }
    }

    struct ProbeSegment {
        let duration: Double
        let uri: URL
    }

    static func selectHighestVariant(from master: String, masterURL: URL) -> URL? {
        variants(from: master, masterURL: masterURL).first?.uri
    }

    /// 按声明码率降序返回前 limit 个 variant（保留 URL 而不是只挑一个）。
    /// CDN 的分辨率标签不可信，调用方要实测分片大小再定档。
    static func topVariants(from master: String, masterURL: URL, limit: Int) -> [URL] {
        Array(variants(from: master, masterURL: masterURL).prefix(limit).map(\.uri))
    }

    static func variants(from master: String, masterURL: URL) -> [StreamVariant] {
        let lines = master.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [StreamVariant] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-STREAM-INF:") {
                let bandwidth = bandwidthValue(in: trimmed) ?? 0
                let resolution = attributeValue(in: trimmed, name: "RESOLUTION") ?? ""
                var uriLine = ""
                var cursor = index + 1
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    cursor += 1
                    if candidate.isEmpty || candidate.hasPrefix("#") { continue }
                    uriLine = candidate
                    break
                }
                if !uriLine.isEmpty, let uri = resolve(uriLine, against: masterURL) {
                    found.append(StreamVariant(bandwidth: bandwidth, resolution: resolution, uri: uri))
                }
                index = cursor
                continue
            }
            index += 1
        }
        return found.sorted { $0.bandwidth > $1.bandwidth }
    }

    /// 路径里的 720P/1080P 优先；没有时用 RESOLUTION 的高度。
    static func qualityLabel(in path: String, resolution: String) -> String {
        let upper = path.uppercased()
        for tag in ["2160P", "1080P", "720P", "480P", "360P", "240P"] {
            if upper.contains(tag) { return tag }
        }
        let parts = resolution.lowercased().split(separator: "x")
        if parts.count == 2, let height = Int(parts[1]) {
            if height >= 1080 { return "1080P" }
            if height >= 720 { return "720P" }
            if height >= 576 { return "576P" }
            if height >= 480 { return "480P" }
            if height >= 360 { return "360P" }
            return "\(height)P"
        }
        if !resolution.isEmpty { return resolution }
        return "unknown"
    }

    /// 声明 1080P 经常是 360p 壳。测量失败时优先 720P，避免误选假 1080。
    static func fallbackScore(for variant: StreamVariant) -> Int {
        let label = variant.qualityLabel.uppercased()
        if label.contains("720") { return 720 }
        if label.contains("576") { return 576 }
        if label.contains("480") { return 480 }
        if label.contains("1080") { return 400 }
        if label.contains("2160") { return 360 }
        if label.contains("360") { return 360 }
        if label.contains("240") { return 240 }
        return min(variant.bandwidth / 1000, 300)
    }

    /// media playlist 中最后一个分片的绝对地址。
    static func lastSegmentURI(from playlist: String, mediaURL: URL) -> URL? {
        segments(from: playlist, mediaURL: mediaURL).last?.uri
    }

    /// 直播最后一片可能还在增长，探测用倒数第二片（只有一片时才用最后一片）。
    static func probeSegment(from playlist: String, mediaURL: URL) -> ProbeSegment? {
        let all = segments(from: playlist, mediaURL: mediaURL)
        guard !all.isEmpty else { return nil }
        if all.count >= 2 {
            return all[all.count - 2]
        }
        return all[0]
    }

    private static func segments(from playlist: String, mediaURL: URL) -> [ProbeSegment] {
        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [ProbeSegment] = []
        var pendingDuration: Double = 0
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXTINF:") {
                let payload = trimmed.dropFirst("#EXTINF:".count)
                let number = payload.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
                pendingDuration = Double(number) ?? 0
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let uri = resolve(trimmed, against: mediaURL) {
                found.append(ProbeSegment(duration: pendingDuration, uri: uri))
            }
            pendingDuration = 0
        }
        return found
    }

    static func rewriteMediaPlaylist(_ playlist: String, mediaURL: URL, segmentProxy: (URL) -> String) -> String {
        var output: [String] = []
        let lines = playlist.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-KEY:") || trimmed.hasPrefix("#EXT-X-MAP:") {
                output.append(rewriteAttributeURI(trimmed, against: mediaURL, segmentProxy: segmentProxy))
                index += 1
                continue
            }
            if trimmed.hasPrefix("#") || trimmed.isEmpty {
                output.append(raw)
                index += 1
                continue
            }
            if let url = resolve(trimmed, against: mediaURL) {
                output.append(segmentProxy(url))
            } else {
                output.append(raw)
            }
            index += 1
        }
        return output.joined(separator: "\n")
    }

    private static func rewriteAttributeURI(_ line: String, against base: URL, segmentProxy: (URL) -> String) -> String {
        guard let range = line.range(of: "URI=\"") else { return line }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return line }
        let uri = String(rest[..<end])
        guard let url = resolve(uri, against: base) else { return line }
        let rewritten = "URI=\"\(segmentProxy(url))\""
        return line.replacingOccurrences(of: "URI=\"\(uri)\"", with: rewritten)
    }

    private static func bandwidthValue(in inf: String) -> Int? {
        guard let raw = attributeValue(in: inf, name: "BANDWIDTH") else { return nil }
        return Int(raw.prefix(while: { $0.isNumber }))
    }

    private static func attributeValue(in inf: String, name: String) -> String? {
        guard let range = inf.range(of: "\(name)=") else { return nil }
        var rest = inf[range.upperBound...]
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        let value = rest.prefix(while: { $0 != "," && !$0.isWhitespace })
        return value.isEmpty ? nil : String(value)
    }

    static func resolve(_ reference: String, against base: URL) -> URL? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("//") {
            return URL(string: (base.scheme ?? "https") + ":" + trimmed)
        }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }
}
