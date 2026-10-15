import Foundation

enum AudioQuality: String, Codable {
    case standard, sq, hr
}

struct Track: Identifiable, Codable, Hashable {
    var path: String
    var title: String
    var artist: String
    var album: String
    var trackNumber: Int?
    var duration: Double
    var sampleRate: Double
    var bitDepth: Int
    var isLossless: Bool
    var modified: Date
    var titleKey: String
    var artistKey: String
    var albumKey: String

    static let unknownArtist = "未知艺术家"
    static let unknownAlbum = "未知专辑"

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var folderPath: String { (path as NSString).deletingLastPathComponent }
    var folderName: String { (folderPath as NSString).lastPathComponent }
    var hasKnownArtist: Bool { artist != Track.unknownArtist }
    var hasKnownAlbum: Bool { album != Track.unknownAlbum }

    /// SQ = 无损（16bit / 44.1–48kHz），HR = 高解析（24bit 以上或采样率高于 48kHz）
    var quality: AudioQuality {
        guard isLossless else { return .standard }
        return (bitDepth > 16 || sampleRate > 48_000) ? .hr : .sq
    }

    init(path: String, title: String, artist: String, album: String, trackNumber: Int?,
         duration: Double, sampleRate: Double, bitDepth: Int, isLossless: Bool, modified: Date) {
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.isLossless = isLossless
        self.modified = modified
        self.titleKey = SortKey.make(title)
        self.artistKey = SortKey.make(artist)
        self.albumKey = SortKey.make(album)
    }
}

struct Playlist: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var paths: [String]
}

/// 专辑 / 艺术家 / 文件夹 分组
struct TrackGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let tracks: [Track]

    static func == (lhs: TrackGroup, rhs: TrackGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 按首字母分出的一段歌曲（A、B、C … #）
struct TrackSection: Identifiable {
    let id: String
    var tracks: [Track]
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}
