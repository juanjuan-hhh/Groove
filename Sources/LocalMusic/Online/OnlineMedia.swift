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

/// 联网获取歌词（LRCLIB，再加上用户自己添加的歌词源），结果缓存在本地，下次直接读取。
/// （以前还从酷狗、QQ 音乐、网易云下载歌词，从 iTunes、酷狗、网易云下载封面，因为版权问题都去掉了；
/// 之前下载好的歌词、封面缓存照旧能用，也能在菜单里删掉）
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

    /// LRCLIB 要求带上能说明是谁的 User-Agent
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1"
        return "Groove/\(version) (https://github.com/juanjuan-hhh/Groove)"
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }()

    static func getData(_ url: URL) async throws -> Data {
        let request = URLRequest(url: url)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: 歌词

    static func fetchLyrics(for track: Track) async -> String? {
        // 先 LRCLIB（只认对得上、带时间轴的），找不到再按顺序试用户自己添加的歌词源（也只要带时间轴的）
        var result = await lrclibLyrics(track)
        if result == nil {
            for source in CustomLyricSources.enabled {
                if let text = await CustomLyricSources.lyrics(for: track, from: source) {
                    result = text
                    break
                }
            }
        }

        if let result {
            try? result.write(to: lyricsFile(track), atomically: true, encoding: .utf8)
        }
        return result
    }

    // MARK: LRCLIB（https://lrclib.net，公开免费，不用 key；国内有时连不上，失败就跳过）

    struct LRCLibItem: Decodable, Sendable {
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?   // 秒
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private static let lrclibTimeout: TimeInterval = 6

    /// /api/search：q 是关键词；也可以按 track_name + artist_name 搜。失败返回 nil
    static func lrclibSearch(query: String? = nil, title: String? = nil, artist: String? = nil) async -> [LRCLibItem]? {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        var items: [URLQueryItem] = []
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        if let title { items.append(URLQueryItem(name: "track_name", value: title)) }
        if let artist { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        comps.queryItems = items
        guard let url = comps.url, let data = try? await lrclibData(url) else { return nil }
        return try? JSONDecoder().decode([LRCLibItem].self, from: data)
    }

    private static func lrclibData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = lrclibTimeout
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 404 { throw URLError(.fileDoesNotExist) }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// 自动找歌词：LRCLIB 中文歌收得少，所以要求很严——歌名、歌手对得上，时长差 3 秒以内，而且带时间轴；
    /// 不然就不要，交给后面用户自己添加的歌词源
    private static func lrclibLyrics(_ track: Track) async -> String? {
        guard track.hasKnownArtist, track.duration > 0, !normalize(track.title).isEmpty else { return nil }
        // 先精确查（歌名 + 歌手 + 专辑 + 时长）
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        var query = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        if track.hasKnownAlbum, !track.album.isBlank { query.append(URLQueryItem(name: "album_name", value: track.album)) }
        comps.queryItems = query
        do {
            if let url = comps.url {
                let item = try JSONDecoder().decode(LRCLibItem.self, from: try await lrclibData(url))
                if lrclibMatches(item, track), let text = nonEmpty(item.syncedLyrics) { return text }
            }
        } catch let error as URLError where error.code != .fileDoesNotExist {
            return nil   // 连不上就别再试搜索了
        } catch {}
        // 精确查不到（专辑名、时长写法不一样）：按歌名 + 歌手搜，再挑时长对得上的
        guard let items = await lrclibSearch(title: track.title, artist: track.artist) else { return nil }
        return items.first { lrclibMatches($0, track) && nonEmpty($0.syncedLyrics) != nil }?.syncedLyrics
    }

    private static func lrclibMatches(_ item: LRCLibItem, _ track: Track) -> Bool {
        guard item.instrumental != true, let d = item.duration, abs(d - track.duration) <= 3 else { return false }
        let wantTitle = normalize(track.title), title = normalize(item.trackName ?? "")
        let wantArtist = normalize(track.artist), artist = normalize(item.artistName ?? "")
        guard !title.isEmpty, title == wantTitle || title.contains(wantTitle) || wantTitle.contains(title) else { return false }
        return !artist.isEmpty && (artist.contains(wantArtist) || wantArtist.contains(artist))
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
