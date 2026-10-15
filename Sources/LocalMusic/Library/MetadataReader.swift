import AVFoundation
import Foundation

/// 读取音频文件自带的信息（歌名、歌手、专辑、音质、内嵌封面、内嵌歌词）
enum MetadataReader {
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "aifc", "caf", "alac", "mp4"
    ]

    static func readTrack(url: URL, modified: Date) async -> Track {
        var title: String?
        var artist: String?
        var album: String?
        var trackNumber: Int?
        var duration = 0.0
        var sampleRate = 0.0
        var bitDepth = 0
        var lossless = false

        if url.pathExtension.lowercased() == "flac", let flac = FLACParser.read(url: url, includePicture: false) {
            title = flac.tags["TITLE"]
            artist = flac.tags["ARTIST"] ?? flac.tags["ALBUMARTIST"]
            album = flac.tags["ALBUM"]
            trackNumber = flac.tags["TRACKNUMBER"].flatMap { Int($0.split(separator: "/").first ?? "") }
            duration = flac.duration
            sampleRate = flac.sampleRate
            bitDepth = flac.bitDepth
            lossless = true
        } else {
            let asset = AVURLAsset(url: url)
            if let items = try? await asset.load(.commonMetadata) {
                title = await string(items, .commonIdentifierTitle)
                artist = await string(items, .commonIdentifierArtist)
                album = await string(items, .commonIdentifierAlbumName)
            }
            if let items = try? await asset.load(.metadata) {
                trackNumber = await readTrackNumber(items)
            }
            if let d = try? await asset.load(.duration), d.seconds.isFinite {
                duration = d.seconds
            }
            if let file = try? AVAudioFile(forReading: url) {
                let desc = file.fileFormat.streamDescription.pointee
                sampleRate = desc.mSampleRate
                switch desc.mFormatID {
                case kAudioFormatLinearPCM:
                    lossless = true
                    bitDepth = Int(desc.mBitsPerChannel)
                case kAudioFormatAppleLossless, kAudioFormatFLAC:
                    lossless = true
                    bitDepth = [1: 16, 2: 20, 3: 24, 4: 32][Int(desc.mFormatFlags)] ?? 16
                default:
                    lossless = false
                }
                if duration == 0, sampleRate > 0 {
                    duration = Double(file.length) / sampleRate
                }
            }
        }

        // 没有标签时从文件名猜："歌手 - 歌名.mp3"
        let fileName = url.deletingPathExtension().lastPathComponent
        if title?.isBlank ?? true {
            let parts = fileName.components(separatedBy: " - ")
            if parts.count >= 2 {
                if artist?.isBlank ?? true { artist = parts[0].trimmingCharacters(in: .whitespaces) }
                title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            } else {
                title = fileName
            }
        }

        return Track(
            path: url.path,
            title: title!.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: (artist?.isBlank ?? true) ? Track.unknownArtist : artist!.trimmingCharacters(in: .whitespacesAndNewlines),
            album: (album?.isBlank ?? true) ? Track.unknownAlbum : album!.trimmingCharacters(in: .whitespacesAndNewlines),
            trackNumber: trackNumber,
            duration: duration,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            isLossless: lossless,
            modified: modified
        )
    }

    /// 文件内嵌的封面图片
    static func embeddedArtwork(url: URL) async -> Data? {
        if url.pathExtension.lowercased() == "flac", let flac = FLACParser.read(url: url, includePicture: true) {
            return flac.picture
        }
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
        }
        return nil
    }

    /// 文件内嵌的歌词
    static func embeddedLyrics(url: URL) async -> String? {
        if url.pathExtension.lowercased() == "flac", let flac = FLACParser.read(url: url, includePicture: false) {
            for key in ["LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS", "UNSYNCED LYRICS"] {
                if let text = flac.tags[key], !text.isBlank { return text }
            }
            return nil
        }
        let asset = AVURLAsset(url: url)
        if let text = try? await asset.load(.lyrics), !text.isBlank { return text }
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items where item.identifier == .id3MetadataUnsynchronizedLyric || item.identifier == .iTunesMetadataLyrics {
            if let text = try? await item.load(.stringValue), !text.isBlank { return text }
        }
        return nil
    }

    private static func string(_ items: [AVMetadataItem], _ id: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first else { return nil }
        return try? await item.load(.stringValue)
    }

    private static func readTrackNumber(_ items: [AVMetadataItem]) async -> Int? {
        for item in items {
            if item.identifier == .id3MetadataTrackNumber, let s = try? await item.load(.stringValue) {
                return Int(s.split(separator: "/").first ?? "")
            }
            if item.identifier == .iTunesMetadataTrackNumber, let d = try? await item.load(.dataValue), d.count >= 4 {
                let b = [UInt8](d)
                return Int(b[2]) << 8 | Int(b[3])
            }
        }
        return nil
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
