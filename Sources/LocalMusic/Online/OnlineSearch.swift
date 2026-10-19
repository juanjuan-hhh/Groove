import Foundation

/// 「联网搜索」面板里的一条结果
struct OnlineCandidate: Identifiable, Sendable {
    /// 歌词只有 LRCLIB 和用户自己添加的源；网易云、iTunes 只提供封面
    enum Source: Hashable, Sendable {
        case lrclib
        case netease
        case itunes
        case custom(CustomLyricSource)

        var label: String {
            switch self {
            case .lrclib: "LRCLIB"
            case .netease: "网易云"
            case .itunes: "iTunes"
            case .custom(let source): source.name.isBlank ? "自定义" : source.name
            }
        }

        /// 只有封面、没有歌词的来源
        var coverOnly: Bool {
            switch self {
            case .netease, .itunes: true
            case .lrclib, .custom: false
            }
        }
    }

    /// 歌词从哪里取
    enum LyricsRef: Sendable {
        case text(String)            // 直接给了歌词文本（LRCLIB、自定义歌词源）
    }

    let id = UUID()
    let source: Source
    let title: String
    let artist: String
    var album: String?
    var duration: Double?
    var coverURL: URL?
    var lyrics: LyricsRef?
    /// 是否带时间轴
    var synced: Bool?
}

/// 一个来源的搜索结果：成功（可能为空）或失败
enum SourceResult: Sendable {
    case ok([OnlineCandidate])
    case failed(String)
}

/// 「联网搜索」：同时查 LRCLIB 和用户自己添加的歌词源（歌词），网易云、iTunes（封面），列出所有候选让用户自己选
enum OnlineSearch {
    static func lrclib(_ query: String) async -> SourceResult {
        guard let items = await OnlineMedia.lrclibSearch(query: query) else { return .failed("连接失败") }
        return .ok(items.prefix(15).compactMap { item in
            let synced = nonBlank(item.syncedLyrics)
            guard let title = item.trackName, let text = synced ?? nonBlank(item.plainLyrics) else { return nil }
            return OnlineCandidate(source: .lrclib, title: title, artist: item.artistName ?? "",
                                   album: nonBlank(item.albumName), duration: item.duration,
                                   lyrics: .text(text), synced: synced != nil)
        })
    }

    /// 用户自己添加的歌词源：{title} 用搜索框里的字，{artist} {album} {duration} 用这首歌的信息；找到就是一条结果
    static func custom(_ source: CustomLyricSource, query: String, track: Track) async -> SourceResult {
        guard CustomLyricSources.url(source.template, title: query, artist: "", album: "", duration: 0) != nil else {
            return .failed("网址无效")
        }
        let artist = track.hasKnownArtist ? track.artist : ""
        let album = track.hasKnownAlbum ? track.album : ""
        guard let result = await CustomLyricSources.fetch(source, title: query, artist: artist, album: album,
                                                          duration: track.duration) else { return .ok([]) }
        return .ok([OnlineCandidate(source: .custom(source), title: query, artist: artist,
                                    album: album.isEmpty ? nil : album, duration: result.duration,
                                    lyrics: .text(result.text), synced: result.synced)])
    }

    static func netease(_ query: String) async -> SourceResult {
        guard let songs = await OnlineMedia.neteaseSearch(query, count: 12) else { return .failed("连接失败") }
        return .ok(songs.compactMap { song in
            guard let cover = OnlineMedia.neteaseCoverURL(song.picURL) else { return nil }
            return OnlineCandidate(source: .netease, title: song.name, artist: song.artists.joined(separator: " / "),
                                   album: song.album, duration: song.duration, coverURL: cover)
        })
    }

    static func itunes(_ query: String) async -> SourceResult {
        struct Response: Decodable {
            struct Item: Decodable {
                let trackName: String?
                let artistName: String?
                let collectionName: String?
                let trackTimeMillis: Double?
                let artworkUrl100: String?
            }
            let results: [Item]
        }
        var all: [OnlineCandidate] = []
        var anySucceeded = false
        for country in ["cn", "us"] {
            var comps = URLComponents(string: "https://itunes.apple.com/search")!
            comps.queryItems = [
                URLQueryItem(name: "term", value: query),
                URLQueryItem(name: "media", value: "music"),
                URLQueryItem(name: "entity", value: "song"),
                URLQueryItem(name: "limit", value: "8"),
                URLQueryItem(name: "country", value: country),
            ]
            guard let url = comps.url, let data = try? await OnlineMedia.getData(url),
                  let response = try? JSONDecoder().decode(Response.self, from: data) else { continue }
            anySucceeded = true
            all += response.results.compactMap { item in
                guard let title = item.trackName, let art = item.artworkUrl100 else { return nil }
                return OnlineCandidate(source: .itunes, title: title, artist: item.artistName ?? "",
                                       album: item.collectionName, duration: item.trackTimeMillis.map { $0 / 1000 },
                                       coverURL: URL(string: art.replacingOccurrences(of: "100x100bb", with: "600x600bb")))
            }
            if !all.isEmpty { break }
        }
        return anySucceeded ? .ok(all) : .failed("连接失败")
    }

    /// 取出候选的歌词文本
    static func lyrics(for candidate: OnlineCandidate) async -> String? {
        switch candidate.lyrics {
        case .text(let text): return text
        case nil: return nil
        }
    }

    static func image(at url: URL) async -> Data? {
        guard let data = try? await OnlineMedia.getData(url), !data.isEmpty else { return nil }
        return data
    }

    private static func nonBlank(_ s: String?) -> String? {
        guard let s, !s.isBlank else { return nil }
        return s
    }
}
