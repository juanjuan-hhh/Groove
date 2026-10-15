import CryptoKit
import Foundation

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalMusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func dir(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum AppSettings {
    static let autoFetchKey = "autoFetchOnline"
    static var autoFetchOnline: Bool {
        UserDefaults.standard.object(forKey: autoFetchKey) as? Bool ?? true
    }
}

/// 联网获取封面（iTunes 搜索接口，找不到再用酷狗）和歌词（先酷狗，再 LRCLIB），结果缓存在本地，下次直接读取。
/// 酷狗用的是客户端内部接口，不是公开 API，任何失败都直接跳过。
enum OnlineMedia {
    // MARK: 缓存

    static func cacheKey(_ track: Track) -> String {
        SHA256.hash(data: Data(track.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func coverFile(_ track: Track) -> URL {
        AppPaths.dir("Covers").appendingPathComponent(cacheKey(track) + ".jpg")
    }

    static func lyricsFile(_ track: Track) -> URL {
        AppPaths.dir("Lyrics").appendingPathComponent(cacheKey(track) + ".lrc")
    }

    static func cachedCover(_ track: Track) -> Data? {
        try? Data(contentsOf: coverFile(track))
    }

    static func cachedLyrics(_ track: Track) -> String? {
        try? String(contentsOf: lyricsFile(track), encoding: .utf8)
    }

    // MARK: 网络

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = ["User-Agent": "LocalMusic/0.1 (macOS personal music player)"]
        return URLSession(configuration: config)
    }()

    private static func getData(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: 封面

    private struct ITunesResponse: Decodable {
        struct Item: Decodable {
            let trackName: String?
            let artistName: String?
            let artworkUrl100: String?
        }
        let results: [Item]
    }

    static func fetchCover(for track: Track) async -> Data? {
        for country in ["cn", "us"] {
            guard let artURL = await searchITunes(track, country: country), let url = URL(string: artURL) else { continue }
            if let data = try? await getData(url), !data.isEmpty {
                try? data.write(to: coverFile(track))
                return data
            }
        }
        if let artURL = await searchKugouCover(track), let url = URL(string: artURL),
           let data = try? await getData(url), !data.isEmpty {
            try? data.write(to: coverFile(track))
            return data
        }
        return nil
    }

    private static func searchITunes(_ track: Track, country: String) async -> String? {
        let artist = track.hasKnownArtist ? track.artist : ""
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: "\(track.title) \(artist)".trimmingCharacters(in: .whitespaces)),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "country", value: country),
        ]
        guard let url = comps.url,
              let data = try? await getData(url),
              let response = try? JSONDecoder().decode(ITunesResponse.self, from: data) else { return nil }

        let wantTitle = normalize(track.title)
        let wantArtist = normalize(artist)
        guard !wantTitle.isEmpty else { return nil }

        var best: (score: Int, art: String)?
        for item in response.results {
            guard let art = item.artworkUrl100 else { continue }
            let title = normalize(item.trackName ?? "")
            let itemArtist = normalize(item.artistName ?? "")
            guard !title.isEmpty else { continue }

            var score = 0
            if title == wantTitle {
                score += 3
            } else if title.contains(wantTitle) || wantTitle.contains(title) {
                score += 1
            } else {
                continue
            }
            if !wantArtist.isEmpty {
                guard !itemArtist.isEmpty,
                      itemArtist.contains(wantArtist) || wantArtist.contains(itemArtist) else { continue }
                score += 3
            }
            if best == nil || score > best!.score { best = (score, art) }
        }
        return best?.art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
    }

    // MARK: 歌词

    private struct LrcLibItem: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    static func fetchLyrics(for track: Track) async -> String? {
        var result = await kugouLyrics(track)

        // 1. LRCLIB 精确匹配（需要歌名、歌手、专辑、时长）
        if result == nil && track.hasKnownArtist && track.hasKnownAlbum {
            var comps = URLComponents(string: "https://lrclib.net/api/get")!
            comps.queryItems = [
                URLQueryItem(name: "track_name", value: track.title),
                URLQueryItem(name: "artist_name", value: track.artist),
                URLQueryItem(name: "album_name", value: track.album),
                URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
            ]
            if let url = comps.url, let data = try? await getData(url),
               let item = try? JSONDecoder().decode(LrcLibItem.self, from: data) {
                result = nonEmpty(item.syncedLyrics) ?? nonEmpty(item.plainLyrics)
            }
        }

        // 2. LRCLIB 模糊搜索
        if result == nil {
            var comps = URLComponents(string: "https://lrclib.net/api/search")!
            var query = [URLQueryItem(name: "track_name", value: track.title)]
            if track.hasKnownArtist { query.append(URLQueryItem(name: "artist_name", value: track.artist)) }
            comps.queryItems = query
            if let url = comps.url, let data = try? await getData(url),
               let items = try? JSONDecoder().decode([LrcLibItem].self, from: data) {
                let wantTitle = normalize(track.title)
                let candidates = items.filter {
                    let t = normalize($0.trackName ?? "")
                    return !t.isEmpty && (t == wantTitle || t.contains(wantTitle) || wantTitle.contains(t))
                }
                func closeDuration(_ item: LrcLibItem) -> Bool {
                    guard let d = item.duration, track.duration > 0 else { return true }
                    return abs(d - track.duration) <= 3
                }
                let synced = candidates.first { nonEmpty($0.syncedLyrics) != nil && closeDuration($0) }
                    ?? candidates.first { nonEmpty($0.syncedLyrics) != nil }
                result = nonEmpty(synced?.syncedLyrics)
                    ?? candidates.lazy.compactMap { nonEmpty($0.plainLyrics) }.first
            }
        }

        if let result {
            try? result.write(to: lyricsFile(track), atomically: true, encoding: .utf8)
        }
        return result
    }

    // MARK: 酷狗

    private struct KugouSongSearch: Decodable {
        struct Item: Decodable {
            let SongName: String?
            let SingerName: String?
            let Image: String?
        }
        struct Payload: Decodable { let lists: [Item] }
        let data: Payload
    }

    private static func searchKugouCover(_ track: Track) async -> String? {
        let artist = track.hasKnownArtist ? track.artist : ""
        var comps = URLComponents(string: "https://songsearch.kugou.com/song_search_v2")!
        comps.queryItems = [
            URLQueryItem(name: "keyword", value: "\(artist) \(track.title)".trimmingCharacters(in: .whitespaces)),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "15"),
            URLQueryItem(name: "platform", value: "WebFilter"),
        ]
        guard let url = comps.url else { return nil }

        // 这个接口连续请求时会限流，返回空列表，等 2 秒重试一次
        var items: [KugouSongSearch.Item] = []
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            guard let data = try? await getData(url),
                  let response = try? JSONDecoder().decode(KugouSongSearch.self, from: data) else { return nil }
            items = response.data.lists
            if !items.isEmpty { break }
        }

        let wantTitle = normalize(track.title)
        let wantArtist = normalize(artist)
        guard !wantTitle.isEmpty else { return nil }

        let match = items.first { item in
            guard let image = item.Image, !image.isEmpty else { return false }
            let title = normalize(item.SongName ?? "")
            guard !title.isEmpty, title == wantTitle || title.contains(wantTitle) || wantTitle.contains(title) else { return false }
            if wantArtist.isEmpty { return true }
            let itemArtist = normalize(item.SingerName ?? "")
            return !itemArtist.isEmpty && (itemArtist.contains(wantArtist) || wantArtist.contains(itemArtist))
        }
        // 图片地址形如 http://imge.kugou.com/stdmusic/{size}/...，改成 https 和 480 尺寸
        return match?.Image?
            .replacingOccurrences(of: "{size}", with: "480")
            .replacingOccurrences(of: "http://", with: "https://")
    }

    private struct KugouLyricsSearch: Decodable {
        struct Candidate: Decodable {
            let id: String?
            let accesskey: String?
            let song: String?
            let duration: Int?   // 毫秒
        }
        let candidates: [Candidate]?
    }

    private struct KugouLyricsDownload: Decodable {
        let content: String?   // base64 编码的 LRC
    }

    private static func kugouLyrics(_ track: Track) async -> String? {
        let keyword = track.hasKnownArtist ? "\(track.artist) - \(track.title)" : track.title
        var comps = URLComponents(string: "https://lyrics.kugou.com/search")!
        var query = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "keyword", value: keyword),
        ]
        if track.duration > 0 {
            query.append(URLQueryItem(name: "duration", value: String(Int(track.duration * 1000))))
        }
        comps.queryItems = query
        guard let url = comps.url,
              let data = try? await getData(url),
              let response = try? JSONDecoder().decode(KugouLyricsSearch.self, from: data) else { return nil }

        let wantTitle = normalize(track.title)
        guard !wantTitle.isEmpty else { return nil }
        let candidates = (response.candidates ?? []).filter {
            let t = normalize($0.song ?? "")
            return $0.id != nil && $0.accesskey != nil
                && !t.isEmpty && (t == wantTitle || t.contains(wantTitle) || wantTitle.contains(t))
        }
        func closeDuration(_ c: KugouLyricsSearch.Candidate) -> Bool {
            guard let d = c.duration, track.duration > 0 else { return true }
            return abs(Double(d) / 1000 - track.duration) <= 3
        }
        // 酷狗已按匹配度排序，优先取时长接近的
        guard let best = candidates.first(where: closeDuration) ?? candidates.first,
              let id = best.id, let key = best.accesskey else { return nil }

        var dl = URLComponents(string: "https://lyrics.kugou.com/download")!
        dl.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "accesskey", value: key),
            URLQueryItem(name: "fmt", value: "lrc"),
            URLQueryItem(name: "charset", value: "utf8"),
        ]
        guard let dlURL = dl.url,
              let dlData = try? await getData(dlURL),
              let item = try? JSONDecoder().decode(KugouLyricsDownload.self, from: dlData),
              let encoded = item.content, let raw = Data(base64Encoded: encoded),
              let text = String(data: raw, encoding: .utf8) else { return nil }
        return nonEmpty(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
    }

    // MARK: 工具

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isBlank else { return nil }
        return s
    }

    /// 统一大小写、繁简，去掉括号内容和符号，用于比较歌名/歌手
    static func normalize(_ s: String) -> String {
        let simplified = s.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? s
        let noBrackets = simplified.replacingOccurrences(of: #"[\(（\[【].*?[\)）\]】]"#, with: "", options: .regularExpression)
        return noBrackets.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
