import Foundation

/// 同一首歌有多个文件（比如 FLAC 和 MP3 各一份）时，列表里只保留音质最好的那一个。
/// 只影响显示和播放，不动原文件。
enum TrackDeduper {
    struct Result {
        var kept: [Track]
        /// 被隐藏的文件路径 → 保留的那个文件的路径
        var alias: [String: String]
    }

    /// 歌名、歌手相同，并且时长相差不超过这么多秒，就算同一首歌（不同来源的文件首尾静音常差 3 秒左右）
    static let durationTolerance: Double = 4
    /// 歌手未知时更严格：时长要几乎一样
    static let unknownArtistTolerance: Double = 1

    static func merge(_ tracks: [Track]) -> Result {
        var groups: [String: [Track]] = [:]
        for track in tracks {
            let title = normalize(track.title)
            guard !title.isEmpty else { continue }
            let artist = track.hasKnownArtist ? normalize(track.artist) : "\u{0}unknown"
            groups["\(title)\u{1}\(artist)", default: []].append(track)
        }

        var alias: [String: String] = [:]
        for list in groups.values where list.count > 1 {
            let tolerance = list[0].hasKnownArtist ? durationTolerance : unknownArtistTolerance
            // 按时长排好，时长接近的连成一簇
            var cluster: [Track] = []
            for track in list.sorted(by: { $0.duration < $1.duration }) {
                if let last = cluster.last, track.duration - last.duration > tolerance {
                    collapse(cluster, into: &alias)
                    cluster = []
                }
                cluster.append(track)
            }
            collapse(cluster, into: &alias)
        }

        let kept = alias.isEmpty ? tracks : tracks.filter { alias[$0.path] == nil }
        return Result(kept: kept, alias: alias)
    }

    private static func collapse(_ cluster: [Track], into alias: inout [String: String]) {
        guard cluster.count > 1 else { return }
        let best = cluster.min(by: isBetter)!
        for track in cluster where track.path != best.path {
            alias[track.path] = best.path
        }
    }

    /// a 是否比 b 更值得保留：HR > SQ > 有损；无损里 FLAC > ALAC/M4A > WAV/AIFF；
    /// 再比采样率、位深、文件大小，最后按路径保证结果稳定
    static func isBetter(_ a: Track, _ b: Track) -> Bool {
        let qa = qualityRank(a), qb = qualityRank(b)
        if qa != qb { return qa > qb }
        let fa = formatRank(a), fb = formatRank(b)
        if fa != fb { return fa > fb }
        if a.sampleRate != b.sampleRate { return a.sampleRate > b.sampleRate }
        if a.bitDepth != b.bitDepth { return a.bitDepth > b.bitDepth }
        let sa = fileSize(a), sb = fileSize(b)
        if sa != sb { return sa > sb }
        return a.path < b.path
    }

    private static func qualityRank(_ t: Track) -> Int {
        switch t.quality {
        case .hr, .dsd: return 2
        case .sq: return 1
        case .standard: return 0
        }
    }

    private static func formatRank(_ t: Track) -> Int {
        switch t.url.pathExtension.lowercased() {
        case "flac": return 3
        case "m4a", "alac": return 2
        case "wav", "aif", "aiff": return 1
        default: return 0
        }
    }

    private static func fileSize(_ t: Track) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: t.path)[.size] as? Int) ?? 0
    }

    /// 统一全角/半角、大小写，去掉空白
    static func normalize(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping
            .lowercased()
            .filter { !$0.isWhitespace }
    }
}
