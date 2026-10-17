import Foundation

/// 「联网搜索」面板里的一条结果
struct OnlineCandidate: Identifiable, Sendable {
    enum Source: String, Sendable {
        case kugou = "酷狗"
        case qq = "QQ 音乐"
        case netease = "网易云"
        case itunes = "iTunes"
    }

    /// 歌词从哪里取
    enum LyricsRef: Sendable {
        case kugouHash(String)       // 酷狗歌曲的 hash，用到时再查歌词
        case kugouID(String, String) // 酷狗歌词的 id + accesskey
        case qqMid(String)           // QQ 音乐的 songmid，用到时再下载歌词
        case neteaseID(Int)          // 网易云的歌曲 id，用到时再下载歌词
        case text(String)            // 直接给了歌词文本
    }

    let id = UUID()
    let source: Source
    let title: String
    let artist: String
    var album: String?
    var duration: Double?
    var coverURL: URL?
    var lyrics: LyricsRef?
    /// 是否带时间轴（酷狗的要下载后才知道，所以一般是 nil）
    var synced: Bool?
}

/// 一个来源的搜索结果：成功（可能为空）或失败
enum SourceResult: Sendable {
    case ok([OnlineCandidate])
    case failed(String)
}

/// 「联网搜索」：同时查 酷狗、QQ 音乐、网易云、iTunes，列出所有候选让用户自己选
enum OnlineSearch {
    static func netease(_ query: String) async -> SourceResult {
        guard let songs = await OnlineMedia.neteaseSearch(query, count: 12) else { return .failed("连接失败") }
        return .ok(songs.map { song in
            OnlineCandidate(source: .netease, title: song.name, artist: song.artists.joined(separator: " / "),
                            album: song.album, duration: song.duration,
                            coverURL: OnlineMedia.neteaseCoverURL(song.picURL), lyrics: .neteaseID(song.id))
        })
    }

    static func qq(_ query: String) async -> SourceResult {
        guard let items = await OnlineMedia.qqSearch(query, count: 12) else { return .failed("连接失败") }
        return .ok(items.compactMap { item in
            guard let mid = item.songmid, let title = item.songname, !title.isEmpty else { return nil }
            let artist = (item.singer ?? []).compactMap(\.name).joined(separator: " / ")
            return OnlineCandidate(source: .qq, title: title, artist: artist,
                                   album: item.albumname.flatMap { $0.isEmpty ? nil : $0 },
                                   duration: item.interval.map(Double.init),
                                   coverURL: OnlineMedia.qqCoverURL(albumMid: item.albummid),
                                   lyrics: .qqMid(mid))
        })
    }

    static func kugou(_ query: String) async -> SourceResult {
        var comps = URLComponents(string: "https://songsearch.kugou.com/song_search_v2")!
        comps.queryItems = [
            URLQueryItem(name: "keyword", value: query),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "12"),
            URLQueryItem(name: "platform", value: "WebFilter"),
        ]
        struct Response: Decodable {
            struct Item: Decodable {
                let SongName: String?
                let SingerName: String?
                let AlbumName: String?
                let Duration: Double?
                let FileHash: String?
                let Image: String?
            }
            struct Payload: Decodable { let lists: [Item] }
            let data: Payload
        }
        guard let url = comps.url else { return .failed("请求无效") }
        // 酷狗歌曲搜索连续请求会限流（返回空列表），只等 2 秒重试一次
        var items: [Response.Item] = []
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            do {
                let data = try await OnlineMedia.getData(url)
                items = try JSONDecoder().decode(Response.self, from: data).data.lists
            } catch {
                return .failed("连接失败")
            }
            if !items.isEmpty { break }
        }
        // 歌曲搜索被限流时，退回到酷狗歌词搜索（只有歌词，没有封面）
        if items.isEmpty { return await kugouLyricsSearch(query) }
        return .ok(items.compactMap { item in
            guard let title = clean(item.SongName), !title.isEmpty else { return nil }
            return OnlineCandidate(
                source: .kugou,
                title: title,
                artist: clean(item.SingerName) ?? "",
                album: clean(item.AlbumName).flatMap { $0.isEmpty ? nil : $0 },
                duration: item.Duration,
                coverURL: item.Image.flatMap { image in
                    image.isEmpty ? nil : URL(string: image
                        .replacingOccurrences(of: "{size}", with: "480")
                        .replacingOccurrences(of: "http://", with: "https://"))
                },
                lyrics: item.FileHash.map { .kugouHash($0) }
            )
        })
    }

    private static func kugouLyricsSearch(_ query: String) async -> SourceResult {
        var comps = URLComponents(string: "https://lyrics.kugou.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "keyword", value: query),
        ]
        guard let url = comps.url, let data = try? await OnlineMedia.getData(url),
              let response = try? JSONDecoder().decode(KugouLyricsSearch.self, from: data) else {
            return .failed("连接失败")
        }
        return .ok((response.candidates ?? []).compactMap { c in
            guard let id = c.id, let key = c.accesskey, let title = c.song else { return nil }
            return OnlineCandidate(source: .kugou, title: title, artist: c.singer ?? "",
                                   duration: c.duration.map { Double($0) / 1000 }, lyrics: .kugouID(id, key))
        })
    }

    struct KugouLyricsSearch: Decodable {
        struct Candidate: Decodable {
            let id: String?
            let accesskey: String?
            let song: String?
            let singer: String?
            let duration: Int?
        }
        let candidates: [Candidate]?
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

    /// 取出候选的歌词文本（酷狗的要再下载一次）
    static func lyrics(for candidate: OnlineCandidate) async -> String? {
        switch candidate.lyrics {
        case .text(let text): return text
        case .kugouID(let id, let key): return await OnlineMedia.kugouDownloadLyrics(id: id, accessKey: key)
        case .qqMid(let mid): return await OnlineMedia.qqDownloadLyrics(mid: mid)
        case .neteaseID(let id): return await OnlineMedia.neteaseDownloadLyrics(id: id)
        case .kugouHash(let hash):
            var comps = URLComponents(string: "https://lyrics.kugou.com/search")!
            comps.queryItems = [
                URLQueryItem(name: "ver", value: "1"),
                URLQueryItem(name: "man", value: "yes"),
                URLQueryItem(name: "client", value: "pc"),
                URLQueryItem(name: "hash", value: hash),
            ]
            guard let url = comps.url, let data = try? await OnlineMedia.getData(url),
                  let response = try? JSONDecoder().decode(KugouLyricsSearch.self, from: data),
                  let best = response.candidates?.first, let id = best.id, let key = best.accesskey else { return nil }
            return await OnlineMedia.kugouDownloadLyrics(id: id, accessKey: key)
        case nil: return nil
        }
    }

    static func image(at url: URL) async -> Data? {
        guard let data = try? await OnlineMedia.getData(url), !data.isEmpty else { return nil }
        return data
    }

    /// 酷狗的歌名里有时带 <em> 高亮标签
    private static func clean(_ s: String?) -> String? {
        s?.replacingOccurrences(of: #"</?em>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func nonBlank(_ s: String?) -> String? {
        guard let s, !s.isBlank else { return nil }
        return s
    }
}
