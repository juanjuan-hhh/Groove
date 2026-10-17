import Foundation

enum AudioQuality: String, Codable {
    case standard, sq, hr, dsd
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

    /// 正在播放页显示的格式信息，例如「FLAC · 16bit · 44.1kHz」「MP3 · 44.1kHz」
    var formatDescription: String {
        // DSD：「DSF · DSD64 · 2.8MHz」
        if let dsd = dsdLabel {
            return [codec, dsd, String(format: "%.1fMHz", sampleRate / 1_000_000)].joined(separator: " · ")
        }
        var parts = [codec]
        if isLossless && bitDepth > 0 { parts.append("\(bitDepth)bit") }
        if sampleRate > 0 {
            let khz = sampleRate / 1000
            parts.append(khz == khz.rounded() ? "\(Int(khz))kHz" : String(format: "%.1fkHz", khz))
        }
        return parts.joined(separator: " · ")
    }

    /// 编码格式：FLAC、ALAC、MP3……
    var codec: String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "flac": return "FLAC"
        case "mp3": return "MP3"
        case "m4a", "mp4", "alac": return isLossless ? "ALAC" : "AAC"
        case "aac": return "AAC"
        case "wav": return "WAV"
        case "aif", "aiff", "aifc": return "AIFF"
        case "caf": return "CAF"
        case "dsf": return "DSF"
        case "dff": return "DFF"
        default: return ext.uppercased()
        }
    }

    /// DSD 文件（.dsf / .dff）：采样率记的是 DSD 采样率（2822400……），位深记 1
    var isDSD: Bool { bitDepth == 1 && DSDFile.extensions.contains(url.pathExtension.lowercased()) }

    /// 「DSD64」「DSD128」……，不是 DSD 时为 nil
    var dsdLabel: String? { isDSD ? "DSD\(Int((sampleRate / 44100).rounded()))" : nil }

    /// SQ = 无损（16bit / 44.1–48kHz），HR = 高解析（24bit 以上或采样率高于 48kHz）
    var quality: AudioQuality {
        if isDSD { return .dsd }
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
