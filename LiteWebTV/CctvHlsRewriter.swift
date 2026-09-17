import Foundation

enum CctvHlsRewriter {
    static func selectHighestVariant(from master: String, masterURL: URL) -> URL? {
        var bestBandwidth = -1
        var bestURI: String?
        let lines = master.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-STREAM-INF:") {
                let bandwidth = bandwidthValue(in: trimmed) ?? 0
                var uriLine = ""
                var cursor = index + 1
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    cursor += 1
                    if candidate.isEmpty || candidate.hasPrefix("#") { continue }
                    uriLine = candidate
                    break
                }
                if !uriLine.isEmpty, bandwidth >= bestBandwidth {
                    bestBandwidth = bandwidth
                    bestURI = uriLine
                }
                index = cursor
                continue
            }
            index += 1
        }
        guard let bestURI else { return nil }
        return resolve(bestURI, against: masterURL)
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
        guard let range = inf.range(of: "BANDWIDTH=") else { return nil }
        let rest = inf[range.upperBound...]
        let digits = rest.prefix(while: { $0.isNumber })
        return Int(digits)
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
