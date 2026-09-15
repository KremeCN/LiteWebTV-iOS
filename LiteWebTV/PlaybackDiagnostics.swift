import Foundation
import Combine
import UIKit

/// 内置播放诊断。记录起播过程，导出前脱敏。不是完整网络抓包。
final class PlaybackDiagnostics: ObservableObject {
    static var buildID: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "diag-20260915f v\(version)(\(build))"
    }

    struct Event: Identifiable {
        let id = UUID()
        let time: Date
        let attempt: Int
        let category: String
        let message: String
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var lastSummary: String = "尚未开始记录"
    @Published private(set) var currentAttempt = 0

    private let sessionID = UUID().uuidString
    private let maxEvents = 400
    private let maxFileBytes = 500_000
    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("litewebtv-playback-diagnostics.log")
    }()

    init() {
        loadPersistedTail()
    }

    func beginSession(_ reason: String) {
        currentAttempt = 0
        log("session-start", "id=\(sessionID) \(reason)")
        beginAttempt("normal playback")
    }

    func beginAttempt(_ reason: String) {
        currentAttempt += 1
        log("attempt", "start #\(currentAttempt) \(reason)")
    }

    func log(_ category: String, _ message: String, attempt: Int? = nil) {
        let event = Event(
            time: Date(),
            attempt: attempt ?? currentAttempt,
            category: category,
            message: redact(message)
        )
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        lastSummary = "#\(event.attempt) [\(category)] \(event.message)"
        appendToDisk(event)
    }

    func clearAll() {
        events.removeAll()
        currentAttempt = 0
        lastSummary = "日志已清空"
        try? FileManager.default.removeItem(at: fileURL)
        log("session", "cleared by user build=\(Self.buildID)")
    }

    func exportedText() -> String {
        var lines: [String] = [
            "LiteWebTV playback diagnostics",
            "build=\(Self.buildID)",
            "exported=\(iso.string(from: Date()))",
            "note=Not a full network capture. URLs and structured diagnostic fields are minimized before storage.",
            ""
        ]
        if let data = try? Data(contentsOf: fileURL),
           let persisted = String(data: data, encoding: .utf8),
           !persisted.isEmpty {
            lines.append(persisted.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            for event in events {
                lines.append("\(iso.string(from: event.time)) #\(event.attempt) [\(event.category)] \(event.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func copyToPasteboard() {
        UIPasteboard.general.string = exportedText()
    }

    func redactURLString(_ raw: String) -> String {
        guard let url = URL(string: raw) else {
            return redact(raw)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.fragment = nil
        if let items = components?.queryItems, !items.isEmpty {
            components?.queryItems = items.map { item in
                URLQueryItem(name: item.name, value: item.value == nil ? nil : "REDACTED")
            }
        }
        return components?.string ?? redact(raw)
    }

    private func redact(_ text: String) -> String {
        var result = text
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = detector.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: redactURLString(String(result[range])))
            }
        }
        let replacements = [
            (#"(?i)((?:sign|signature|token|key|auth|license|secret|passwd|password)=)([^&\s"']+)"#, "$1REDACTED"),
            (#"(?i)((?:wsSecret|wsTime|uid|uid_s)=)([^&\s"']+)"#, "$1REDACTED"),
            (#"(?i)([\"']?(?:sign|signature|token|key|auth|license|secret|passwd|password|wsSecret|wsTime|uid|uid_s)[\"']?\s*:\s*)[\"'][^\"']*[\"']"#, "$1\"REDACTED\"")
        ]
        for (pattern, template) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: template
                )
            }
        }
        if result.count > 800 {
            result = String(result.prefix(800)) + "…"
        }
        return result
    }

    private func appendToDisk(_ event: Event) {
        let line = "\(iso.string(from: event.time)) #\(event.attempt) [\(event.category)] \(event.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: fileURL)
        }
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int,
              size > maxFileBytes,
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let currentSessionNeedle = "[session-start] id=\(sessionID) "
        let sessionStart = lines.lastIndex(where: { $0.contains(currentSessionNeedle) }) ?? 0
        let previousEvidence = Array(lines.prefix(min(60, sessionStart)))
        let sessionLines = Array(lines[sessionStart...])
        let keySessionLines = sessionLines.filter { !$0.contains("[video]") || !$0.contains("event=progress") }
        let marker = "--- log rotated: video progress samples were removed before older non-current-session records ---"
        var retainedLines = previousEvidence + [marker] + keySessionLines
        if retainedLines.joined(separator: "\n").utf8.count > maxFileBytes * 3 / 4 {
            retainedLines = [marker] + keySessionLines
        }
        var retained = retainedLines.joined(separator: "\n") + "\n"
        if retained.utf8.count > maxFileBytes * 3 / 4 {
            let currentOpening = Array(keySessionLines.prefix(120))
            let currentRecent = Array(keySessionLines.suffix(1_500))
            retained = (currentOpening + [
                "--- log rotated: middle current-session records omitted due to the hard size limit ---"
            ] + currentRecent).joined(separator: "\n") + "\n"
        }
        try? retained.data(using: .utf8)?.write(to: fileURL)
    }

    private func loadPersistedTail() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return }
        let lines = text.split(whereSeparator: \.isNewline).suffix(80)
        for line in lines {
            events.append(Event(time: Date(), attempt: 0, category: "persisted", message: String(line)))
        }
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }
}
