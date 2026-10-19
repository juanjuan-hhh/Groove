import Foundation

/// 用户自己添加的歌词源：一个网址模板，{title} {artist} {album} {duration} 换成这首歌的信息（会做网址编码）。
/// 返回内容可以是 LRC 文本，也可以是 LRCLIB 格式的 JSON（对象或数组，取 syncedLyrics / plainLyrics）。
/// 自动联网时排在 LRCLIB 后面，按列表顺序试，只要带时间轴的；「联网搜索」面板里每个源一栏
struct CustomLyricSource: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var template: String
    var enabled = true
}

/// 一次查询的结果
struct CustomLyricResult: Sendable {
    let text: String
    let synced: Bool
    /// JSON 里带了时长（秒）就记下，用来和本地歌曲比对
    let duration: Double?
}

enum CustomLyricSources {
    static let key = "customLyricSources"

    /// 默认一个都没有
    static func load() -> [CustomLyricSource] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([CustomLyricSource].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [CustomLyricSource]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    static var enabled: [CustomLyricSource] { load().filter { $0.enabled && !$0.template.isBlank } }

    /// 把模板里的占位符换成歌曲信息，得到网址；模板不是 http(s) 网址时返回 nil
    static func url(_ template: String, title: String, artist: String, album: String, duration: Double) -> URL? {
        func encode(_ s: String) -> String {
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=?+#/")
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        let filled = template.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{title}", with: encode(title))
            .replacingOccurrences(of: "{artist}", with: encode(artist))
            .replacingOccurrences(of: "{album}", with: encode(album))
            .replacingOccurrences(of: "{duration}", with: duration > 0 ? String(Int(duration.rounded())) : "")
        guard let url = URL(string: filled), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// 按这首歌的信息查一个源；找不到、连不上、看不懂返回 nil
    static func fetch(_ source: CustomLyricSource, title: String, artist: String, album: String,
                      duration: Double) async -> CustomLyricResult? {
        guard let url = url(source.template, title: title, artist: artist, album: album, duration: duration),
              let data = try? await OnlineMedia.getData(url) else { return nil }
        return parse(data)
    }

    /// 自动联网用：拿这首歌的信息查，只要带时间轴的；返回里带了时长的话，和本地差 3 秒以上不要
    static func lyrics(for track: Track, from source: CustomLyricSource) async -> String? {
        let artist = track.hasKnownArtist ? track.artist : ""
        let album = track.hasKnownAlbum ? track.album : ""
        guard let result = await fetch(source, title: track.title, artist: artist, album: album, duration: track.duration),
              result.synced else { return nil }
        if let d = result.duration, track.duration > 0, abs(d - track.duration) > 3 { return nil }
        return result.text
    }

    /// 看懂返回的内容：JSON（LRCLIB 格式，对象或数组）或者直接是歌词文本
    static func parse(_ data: Data) -> CustomLyricResult? {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            let items: [[String: Any]]
            if let object = json as? [String: Any] {
                items = [object]
            } else if let array = json as? [[String: Any]] {
                items = array
            } else {
                return nil
            }
            // 数组里优先挑带时间轴的那一条
            func text(_ item: [String: Any], _ key: String) -> String? {
                guard let s = item[key] as? String, !s.isBlank else { return nil }
                return s
            }
            if let item = items.first(where: { text($0, "syncedLyrics") != nil }), let synced = text(item, "syncedLyrics") {
                return CustomLyricResult(text: synced, synced: true, duration: item["duration"] as? Double)
            }
            if let item = items.first(where: { text($0, "plainLyrics") != nil }), let plain = text(item, "plainLyrics") {
                return CustomLyricResult(text: plain, synced: hasTimestamps(plain), duration: item["duration"] as? Double)
            }
            return nil
        }
        guard let raw = LyricsProvider.decode(data) else { return nil }
        let text = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
        // 看起来是网页（返回了错误页之类）就不要
        guard !text.isBlank, !text.lowercased().contains("<html") else { return nil }
        return CustomLyricResult(text: text, synced: hasTimestamps(text), duration: nil)
    }

    private static func hasTimestamps(_ text: String) -> Bool {
        LRCParser.parse(text).first?.time != nil
    }
}
