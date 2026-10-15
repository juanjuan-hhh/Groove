import Foundation

/// 把歌名、歌手名转成用于排序的拼音/英文 key。
/// 中文用系统自带的汉字转拼音（不需要联网），例如 "爱，很简单" -> "ai, hen jian dan"。
enum SortKey {
    static func make(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉开头的符号，比如《》、括号、引号
        while let c = s.first, !(c.isLetter || c.isNumber) {
            s.removeFirst()
        }
        guard !s.isEmpty else { return "" }
        let latin = s.applyingTransform(.toLatin, reverse: false) ?? s
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return plain.lowercased()
    }

    /// 分组字母：A–Z，其它（数字、符号）归到 "#"
    static func section(_ key: String) -> String {
        guard let c = key.unicodeScalars.first, c.isASCII,
              CharacterSet.lowercaseLetters.contains(c) else { return "#" }
        return String(Character(c)).uppercased()
    }

    /// A–Z 在前，"#" 在最后
    static func less(_ a: String, _ b: String) -> Bool {
        let sa = section(a), sb = section(b)
        if sa != sb {
            if sa == "#" { return false }
            if sb == "#" { return true }
            return sa < sb
        }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    /// 只保留字母和数字，用于拼音搜索（"aihenjiandan"）
    static func compact(_ key: String) -> String {
        key.filter { $0.isLetter || $0.isNumber }
    }

    /// 拼音首字母，用于搜索（"爱很简单" -> "ahjd"）
    static func initials(_ key: String) -> String {
        key.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .compactMap(\.first)
            .map(String.init)
            .joined()
    }
}
