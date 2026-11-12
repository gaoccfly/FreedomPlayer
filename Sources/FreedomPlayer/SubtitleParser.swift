import Foundation

struct SubtitleCue: Equatable, Hashable {
    let start: Double
    let end: Double
    let text: String
}

enum SubtitleParser {
    static func load(from url: URL) -> [SubtitleCue] {
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        // 优先 UTF-8，失败则尝试 GB18030（国内常见字幕编码）
        guard let raw = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: gb18030)) else {
            return []
        }
        return parse(raw)
    }

    /// 同时支持 SRT 和 WebVTT
    static func parse(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let pattern = "((?:\\d+:)?\\d{1,2}:\\d{2}[.,]\\d{1,3})\\s*-->\\s*((?:\\d+:)?\\d{1,2}:\\d{2}[.,]\\d{1,3})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var cues = [SubtitleCue]()
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timeLineIdx = lines.firstIndex(where: {
                regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
            }) else { continue }

            let line = lines[timeLineIdx]
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let s = timestamp(line, match, at: 1),
                  let e = timestamp(line, match, at: 2),
                  timeLineIdx + 1 < lines.count else { continue }

            let textLines = lines[(timeLineIdx + 1)...]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "WEBVTT" }
            guard !textLines.isEmpty else { continue }
            cues.append(SubtitleCue(start: s, end: e, text: textLines.joined(separator: "\n")))
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func timestamp(_ line: String, _ match: NSTextCheckingResult, at index: Int) -> Double? {
        guard let r = Range(match.range(at: index), in: line) else { return nil }
        let clean = String(line[r]).replacingOccurrences(of: ",", with: ".")
        var seconds = 0.0
        for part in clean.split(separator: ":") {
            seconds = seconds * 60 + (Double(part) ?? 0)
        }
        return seconds
    }
}
