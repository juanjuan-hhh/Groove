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
    /// 锁屏 / 控制中心 / 灵动岛上，歌手那一行换成当前唱到的歌词
    static let lockScreenLyricsKey = "lockScreenLyrics"
    static var lockScreenLyrics: Bool {
        UserDefaults.standard.object(forKey: lockScreenLyricsKey) as? Bool ?? true
    }

    static let autoFetchKey = "autoFetchOnline"
    static var autoFetchOnline: Bool {
        UserDefaults.standard.object(forKey: autoFetchKey) as? Bool ?? true
    }
}

/// 联网获取封面（iTunes 搜索接口，找不到再用酷狗）和歌词（酷狗），结果缓存在本地，下次直接读取。
/// 酷狗用的是客户端内部接口，不是公开 API，任何失败都直接跳过。
enum OnlineMedia {
    // MARK: 缓存

    static func cacheKey(_ track: Track) -> String {
        cacheKey(path: track.path)
    }

    static func cacheKey(path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 歌曲路径换了格式（见 LibraryRoots）：把缓存的封面、歌词改成新名字
    static func migrateCache(_ pairs: [(old: String, new: String)]) {
        let fm = FileManager.default
        let kinds = [("Covers", [".jpg", ".manual.jpg", ".none"]), ("Lyrics", [".lrc", ".manual.lrc", ".none"])]
        for (old, new) in pairs where old != new {
            let from = cacheKey(path: old), to = cacheKey(path: new)
            for (dir, suffixes) in kinds {
                let folder = AppPaths.dir(dir)
                for suffix in suffixes {
                    let src = folder.appendingPathComponent(from + suffix)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    let dst = folder.appendingPathComponent(to + suffix)
                    try? fm.removeItem(at: dst)
                    try? fm.moveItem(at: src, to: dst)
                }
            }
        }
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

    // MARK: 手动选择（在「联网搜索」面板里选的，优先级最高）

    static func manualCoverFile(_ track: Track) -> URL {
        AppPaths.dir("Covers").appendingPathComponent(cacheKey(track) + ".manual.jpg")
    }

    static func manualLyricsFile(_ track: Track) -> URL {
        AppPaths.dir("Lyrics").appendingPathComponent(cacheKey(track) + ".manual.lrc")
    }

    static func manualCover(_ track: Track) -> Data? {
        try? Data(contentsOf: manualCoverFile(track))
    }

    static func manualLyrics(_ track: Track) -> String? {
        try? String(contentsOf: manualLyricsFile(track), encoding: .utf8)
    }

    /// 有没有 App 下载或手动选择的封面（只看文件在不在，不读内容）
    static func hasOnlineCover(_ track: Track) -> Bool {
        FileManager.default.fileExists(atPath: manualCoverFile(track).path)
            || FileManager.default.fileExists(atPath: coverFile(track).path)
    }

    /// 删掉后留一个标记，自动联网不再给这首歌下载（手动搜索不受影响）
    private static func blockFile(_ track: Track, kind: String) -> URL {
        AppPaths.dir(kind).appendingPathComponent(cacheKey(track) + ".none")
    }

    static func isCoverBlocked(_ track: Track) -> Bool {
        FileManager.default.fileExists(atPath: blockFile(track, kind: "Covers").path)
    }

    static func isLyricsBlocked(_ track: Track) -> Bool {
        FileManager.default.fileExists(atPath: blockFile(track, kind: "Lyrics").path)
    }

    static func saveManualCover(_ data: Data, for track: Track) {
        try? data.write(to: manualCoverFile(track))
        try? FileManager.default.removeItem(at: blockFile(track, kind: "Covers"))
    }

    static func saveManualLyrics(_ text: String, for track: Track) {
        try? text.write(to: manualLyricsFile(track), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: blockFile(track, kind: "Lyrics"))
    }

    /// 只删 App 自己下载/选择的封面，不动音乐文件
    static func deleteOnlineCover(_ track: Track) {
        try? FileManager.default.removeItem(at: manualCoverFile(track))
        try? FileManager.default.removeItem(at: coverFile(track))
        FileManager.default.createFile(atPath: blockFile(track, kind: "Covers").path, contents: nil)
    }

    /// 只删 App 自己下载/选择的歌词，不动音乐文件和同名 .lrc
    static func deleteOnlineLyrics(_ track: Track) {
        try? FileManager.default.removeItem(at: manualLyricsFile(track))
        try? FileManager.default.removeItem(at: lyricsFile(track))
        FileManager.default.createFile(atPath: blockFile(track, kind: "Lyrics").path, contents: nil)
    }

    // MARK: 网络

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = ["User-Agent": "LocalMusic/0.1 (macOS personal music player)"]
        return URLSession(configuration: config)
    }()

    /// referer：QQ 音乐的接口要带上 y.qq.com 的来源页，不然不给结果
    static func getData(_ url: URL, referer: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    static func postJSON(_ url: URL, body: Data, referer: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: request)
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
        for find in [searchKugouCover, neteaseCover] {
            if let artURL = await find(track), let url = URL(string: artURL),
               let data = try? await getData(url), !data.isEmpty {
                try? data.write(to: coverFile(track))
                return data
            }
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

    static func fetchLyrics(for track: Track) async -> String? {
        // 先酷狗，找不到再 QQ 音乐，再网易云（LRCLIB 在国内一直连不上，已经去掉）
        var result = await kugouLyrics(track)
        if result == nil { result = await qqLyrics(track) }
        if result == nil { result = await neteaseLyrics(track) }

        if let result {
            try? result.write(to: lyricsFile(track), atomically: true, encoding: .utf8)
        }
        return result
    }

    // MARK: QQ 音乐（和酷狗一样是客户端内部接口，任何失败都直接跳过）

    static let qqReferer = "https://y.qq.com"

    /// 搜索结果里的一首歌（字段名沿用旧接口的，别处都按这个用）
    struct QQSearch {
        struct Singer { let name: String? }
        struct Item {
            let songmid: String?
            let songname: String?
            let singer: [Singer]?
            let albumname: String?
            let albummid: String?
            let interval: Int?   // 秒
        }
    }

    /// 新搜索接口（u.y.qq.com/cgi-bin/musicu.fcg）返回的格式
    private struct QQMusicuResponse: Decodable {
        struct Named: Decodable { let mid: String?; let name: String? }
        struct Song: Decodable {
            let mid: String?
            let name: String?
            let singer: [Named]?
            let album: Named?
            let interval: Int?
        }
        struct SongList: Decodable { let list: [Song] }
        struct Body: Decodable { let song: SongList }
        struct DataField: Decodable { let body: Body }
        struct Req: Decodable { let code: Int; let data: DataField? }
        let req: Req
    }

    /// QQ 音乐歌曲搜索。旧接口 c.y.qq.com/soso/fcgi-bin/client_search_cp 在 2026-10 停用了（一直返回 500），
    /// 改用 QQ 音乐网页版自己用的 musicu.fcg。偶尔连不上时隔一会儿再试一次。
    static func qqSearch(_ keyword: String, count: Int) async -> [QQSearch.Item]? {
        let body: [String: Any] = [
            "comm": ["ct": "19", "cv": "1859", "uin": "0"],
            "req": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicDesktop",
                "param": ["query": keyword, "num_per_page": count, "page_num": 1, "search_type": 0, "grp": 1],
            ],
        ]
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg"),
              let json = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(600)) }
            guard let data = try? await postJSON(url, body: json, referer: qqReferer),
                  let response = try? JSONDecoder().decode(QQMusicuResponse.self, from: data),
                  response.req.code == 0, let songs = response.req.data?.body.song.list else { continue }
            return songs.map {
                QQSearch.Item(songmid: $0.mid, songname: $0.name,
                              singer: $0.singer?.map { QQSearch.Singer(name: $0.name) },
                              albumname: $0.album?.name, albummid: $0.album?.mid, interval: $0.interval)
            }
        }
        return nil
    }

    /// 按 songmid 下载 QQ 音乐的 LRC 歌词
    static func qqDownloadLyrics(mid: String) async -> String? {
        var comps = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
        comps.queryItems = [
            URLQueryItem(name: "songmid", value: mid),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "nobase64", value: "1"),
        ]
        struct Response: Decodable { let lyric: String? }
        guard let url = comps.url, let data = try? await getData(url, referer: qqReferer),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              let text = response.lyric else { return nil }
        return nonEmpty(decodeHTMLEntities(text))
    }

    /// QQ 专辑封面
    static func qqCoverURL(albumMid: String?) -> URL? {
        guard let mid = albumMid, !mid.isEmpty else { return nil }
        return URL(string: "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(mid).jpg")
    }

    /// 自动找歌词：只用歌名搜，再按歌名、歌手、时长挑最像的一首
    private static func qqLyrics(_ track: Track) async -> String? {
        guard let items = await qqSearch(track.title, count: 15) else { return nil }
        let wantTitle = normalize(track.title)
        let wantArtist = track.hasKnownArtist ? normalize(track.artist) : ""
        guard !wantTitle.isEmpty else { return nil }
        func score(_ item: QQSearch.Item) -> Int? {
            let title = normalize(item.songname ?? "")
            guard !title.isEmpty, title == wantTitle || title.contains(wantTitle) || wantTitle.contains(title) else { return nil }
            var s = title == wantTitle ? 3 : 1
            if !wantArtist.isEmpty {
                let artists = (item.singer ?? []).map { normalize($0.name ?? "") }
                if artists.contains(where: { !$0.isEmpty && ($0.contains(wantArtist) || wantArtist.contains($0)) }) { s += 3 }
            }
            if let d = item.interval, track.duration > 0, abs(Double(d) - track.duration) <= 3 { s += 2 }
            return s
        }
        let best = items.compactMap { item in score(item).map { (item, $0) } }.max { $0.1 < $1.1 }
        guard let mid = best?.0.songmid else { return nil }
        return await qqDownloadLyrics(mid: mid)
    }

    // MARK: 网易云音乐（网页版自己用的接口，任何失败都直接跳过）

    static let neteaseReferer = "https://music.163.com"

    struct NetEaseSong: Sendable {
        let id: Int
        let name: String
        let artists: [String]
        let album: String?
        let duration: Double?   // 秒
        let picURL: String?
    }

    private struct NetEaseSearchResponse: Decodable {
        struct Named: Decodable { let name: String? }
        struct Album: Decodable { let name: String?; let picUrl: String? }
        struct Song: Decodable {
            let id: Int
            let name: String?
            let ar: [Named]?
            let al: Album?
            let dt: Double?   // 毫秒
        }
        struct Result: Decodable { let songs: [Song]? }
        let code: Int
        let result: Result?
    }

    /// 网易云歌曲搜索（cloudsearch：结果带歌手、专辑封面、时长，比旧的 /api/search/get 准）
    static func neteaseSearch(_ keyword: String, count: Int) async -> [NetEaseSong]? {
        var comps = URLComponents(string: "https://music.163.com/api/cloudsearch/pc")!
        comps.queryItems = [
            URLQueryItem(name: "s", value: keyword),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: String(count)),
            URLQueryItem(name: "offset", value: "0"),
        ]
        guard let url = comps.url,
              let data = try? await getData(url, referer: neteaseReferer),
              let response = try? JSONDecoder().decode(NetEaseSearchResponse.self, from: data),
              response.code == 200 else { return nil }
        return (response.result?.songs ?? []).compactMap { song in
            guard let name = song.name, !name.isEmpty else { return nil }
            return NetEaseSong(id: song.id, name: name, artists: (song.ar ?? []).compactMap(\.name),
                               album: song.al?.name.flatMap { $0.isEmpty ? nil : $0 },
                               duration: song.dt.map { $0 / 1000 }, picURL: song.al?.picUrl)
        }
    }

    /// 按歌曲 id 下载网易云的 LRC 歌词（纯音乐、没收录歌词的返回 nil）
    static func neteaseDownloadLyrics(id: Int) async -> String? {
        var comps = URLComponents(string: "https://music.163.com/api/song/lyric")!
        comps.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "tv", value: "-1"),
        ]
        struct Response: Decodable {
            struct Lrc: Decodable { let lyric: String? }
            let lrc: Lrc?
            let nolyric: Bool?
            let uncollected: Bool?
        }
        guard let url = comps.url, let data = try? await getData(url, referer: neteaseReferer),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.nolyric != true, response.uncollected != true,
              let text = response.lrc?.lyric else { return nil }
        return nonEmpty(text)
    }

    /// 网易云专辑封面（改成 https、500 尺寸）
    static func neteaseCoverURL(_ pic: String?) -> URL? {
        guard let pic, !pic.isEmpty else { return nil }
        return URL(string: pic.replacingOccurrences(of: "http://", with: "https://") + "?param=500y500")
    }

    /// 自动找：用「歌手 歌名」搜，再按歌名、歌手、时长挑最像的一首
    private static func neteaseBest(_ track: Track, needsCover: Bool) async -> NetEaseSong? {
        let keyword = track.hasKnownArtist ? "\(track.artist) \(track.title)" : track.title
        guard let songs = await neteaseSearch(keyword, count: 15) else { return nil }
        let wantTitle = normalize(track.title)
        let wantArtist = track.hasKnownArtist ? normalize(track.artist) : ""
        guard !wantTitle.isEmpty else { return nil }
        func score(_ song: NetEaseSong) -> Int? {
            if needsCover && (song.picURL ?? "").isEmpty { return nil }
            let title = normalize(song.name)
            guard !title.isEmpty, title == wantTitle || title.contains(wantTitle) || wantTitle.contains(title) else { return nil }
            var s = title == wantTitle ? 3 : 1
            if !wantArtist.isEmpty {
                let artists = song.artists.map(normalize)
                guard artists.contains(where: { !$0.isEmpty && ($0.contains(wantArtist) || wantArtist.contains($0)) }) else { return nil }
                s += 3
            }
            if let d = song.duration, track.duration > 0, abs(d - track.duration) <= 3 { s += 2 }
            return s
        }
        // 分数一样时取靠前的（网易云已按匹配度排序）
        var best: (song: NetEaseSong, score: Int)?
        for song in songs {
            if let sc = score(song), sc > (best?.score ?? -1) { best = (song, sc) }
        }
        return best?.song
    }

    private static func neteaseLyrics(_ track: Track) async -> String? {
        guard let song = await neteaseBest(track, needsCover: false) else { return nil }
        return await neteaseDownloadLyrics(id: song.id)
    }

    private static func neteaseCover(_ track: Track) async -> String? {
        await neteaseBest(track, needsCover: true).flatMap { neteaseCoverURL($0.picURL)?.absoluteString }
    }

    /// QQ 的歌词里偶尔有 &#58; &apos; 这类网页转义
    private static func decodeHTMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in [("&apos;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        let regex = try! NSRegularExpression(pattern: "&#(\\d+);")
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if let code = UInt32(ns.substring(with: m.range(at: 1))), let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result.replacingOccurrences(of: "&amp;", with: "&")
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
        // 先用「歌手 - 歌名」搜（2026-10 起只用歌名搜，热门歌常常一条都不返回），搜不到再只用歌名
        var keywords = [track.title]
        if track.hasKnownArtist { keywords.insert("\(track.artist) - \(track.title)", at: 0) }
        for keyword in keywords {
            if let text = await kugouLyrics(track, keyword: keyword) { return text }
        }
        return nil
    }

    private static func kugouLyrics(_ track: Track, keyword: String) async -> String? {
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
        return await kugouDownloadLyrics(id: id, accessKey: key)
    }

    /// 按酷狗歌词的 id 和 accesskey 下载 LRC
    static func kugouDownloadLyrics(id: String, accessKey key: String) async -> String? {
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
