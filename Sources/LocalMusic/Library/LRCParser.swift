import Foundation

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double?   // nil 表示没有时间轴的纯文本歌词
    let text: String
}

/// 解析 LRC 歌词：[mm:ss.xx]歌词，支持一行多个时间、[offset:] 偏移、逐字时间标记
enum LRCParser {
    private static let timeTag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)

    static func parse(_ raw: String) -> [LyricLine] {
        var offset = 0.0
        var timed: [(Double, String)] = []
        var plain: [String] = []

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let ns = line as NSString

            if line.lowercased().hasPrefix("[offset:") {
                let value = line.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)
                offset = (Double(value) ?? 0) / 1000
                continue
            }

            let matches = timeTag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            var times: [Double] = []
            var end = 0
            for m in matches where m.range.location == end {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let secText = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")
                times.append(minutes * 60 + (Double(secText) ?? 0))
                end = m.range.location + m.range.length
            }

            if times.isEmpty {
                // [ar:歌手] [ti:歌名] 这类信息标签不显示
                if line.hasPrefix("[") && line.hasSuffix("]") { continue }
                plain.append(line)
                continue
            }

            let text = ns.substring(from: end)
                .replacingOccurrences(of: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for t in times { timed.append((max(0, t - offset), text)) }
        }

        if !timed.isEmpty {
            return timed.sorted { $0.0 < $1.0 }
                .enumerated()
                .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
        }
        return plain.enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
    }

    /// 当前时间对应第几行歌词
    static func index(in lines: [LyricLine], at time: Double) -> Int? {
        guard let first = lines.first?.time, time >= first else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if (lines[mid].time ?? 0) <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
