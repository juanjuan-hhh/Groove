import Foundation

/// 「联网搜索」面板里的一条结果
struct OnlineCandidate: Identifiable, Sendable {
    /// 歌词只有 LRCLIB 和用户自己添加的源
    enum Source: Hashable, Sendable {
        case lrclib
        case custom(CustomLyricSource)

        var label: String {
            switch self {
            case .lrclib: "LRCLIB"
            case .custom(let source): source.name.isBlank ? "自定义" : source.name
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
    var lyrics: LyricsRef?
    /// 是否带时间轴
    var synced: Bool?
}

/// 一个来源的搜索结果：成功（可能为空）或失败
enum SourceResult: Sendable {
    case ok([OnlineCandidate])
    case failed(String)
}

/// 「联网搜索」：同时查 LRCLIB 和用户自己添加的歌词源，列出所有候选让用户自己选
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

    /// 取出候选的歌词文本
    static func lyrics(for candidate: OnlineCandidate) async -> String? {
        switch candidate.lyrics {
        case .text(let text): return text
        case nil: return nil
        }
    }

    private static func nonBlank(_ s: String?) -> String? {
        guard let s, !s.isBlank else { return nil }
        return s
    }
}
