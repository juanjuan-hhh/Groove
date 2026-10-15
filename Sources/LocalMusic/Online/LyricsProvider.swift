import Foundation

enum LyricsSource: String {
    case embedded = "文件内嵌"
    case lrcFile = "LRC 文件"
    case online = "网络"
}

/// 本地歌词加载顺序：文件内嵌 → 同名 .lrc 文件 → 之前联网下载的缓存
enum LyricsProvider {
    static func local(for track: Track) async -> (text: String, source: LyricsSource)? {
        if let text = await MetadataReader.embeddedLyrics(url: track.url) {
            return (text, .embedded)
        }
        let lrc = track.url.deletingPathExtension().appendingPathExtension("lrc")
        if let data = try? Data(contentsOf: lrc), let text = decode(data), !text.isBlank {
            return (text, .lrcFile)
        }
        if let text = OnlineMedia.cachedLyrics(track), !text.isBlank {
            return (text, .online)
        }
        return nil
    }

    /// 很多中文 .lrc 是 GBK 编码，UTF-8 读不出来时再试 GB18030
    private static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(data: data, encoding: .utf16)
    }
}
