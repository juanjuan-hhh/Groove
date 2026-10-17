import Foundation

/// DSD 音频文件（.dsf / .dff）的格式信息和标签。
/// DSF：小端，"DSD " + "fmt " + "data" 三段，每个声道按 4096 字节一块轮流存放，块里每个字节先放最早的那一位（LSB first），
/// 文件末尾（metadata 指针处）是 ID3v2 标签。
/// DFF（DSDIFF）：大端，FRM8 里有 PROP（采样率、声道）、"DSD "（各声道逐字节交错，MSB first），
/// 歌名在 DIIN/DITI，有的软件还会加一个非标准的 "ID3 " 块
struct DSDFile: Sendable {
    enum Container: Sendable { case dsf, dff }

    var container: Container
    var channels: Int
    /// 2822400（DSD64）、5644800（DSD128）……
    var sampleRate: Int
    /// 每个声道有多少字节的 DSD 数据（1 字节 = 8 个采样）
    var bytesPerChannel: Int
    /// 音频数据在文件里的起点
    var dataOffset: Int
    /// DSF 每块的字节数（每个声道），DFF 为 1（逐字节交错）
    var blockSize: Int
    /// 字节里最早的采样在最低位（DSF 一般是这样）
    var lsbFirst: Bool
    /// DFF 用 DST 压缩时不能直接播放
    var compressed = false

    var title: String?
    var artist: String?
    var album: String?
    var trackNumber: Int?
    var lyrics: String?
    var picture: Data?

    var duration: Double { sampleRate > 0 ? Double(bytesPerChannel) * 8 / Double(sampleRate) : 0 }
    /// 64、128、256……
    var multiple: Int { sampleRate / 44100 }

    static let extensions: Set<String> = ["dsf", "dff"]

    static func read(url: URL, includePicture: Bool = false) -> DSDFile? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let magic = try? fh.read(upToCount: 4), magic.count == 4 else { return nil }
        switch String(decoding: magic, as: UTF8.self) {
        case "DSD ": return readDSF(fh, includePicture: includePicture)
        case "FRM8": return readDFF(fh, includePicture: includePicture)
        default: return nil
        }
    }

    // MARK: DSF

    private static func readDSF(_ fh: FileHandle, includePicture: Bool) -> DSDFile? {
        // "DSD " 块：大小(8) 文件总长(8) 标签位置(8)
        guard (try? fh.seek(toOffset: 0)) != nil, let head = try? fh.read(upToCount: 28 + 52 + 12), head.count == 92 else { return nil }
        let b = [UInt8](head)
        let metadataOffset = Int(le64(b, 20))
        // "fmt " 块从 28 开始
        guard String(decoding: b[28..<32], as: UTF8.self) == "fmt " else { return nil }
        let f = 28 + 12
        let channels = Int(le32(b, f + 12))
        let rate = Int(le32(b, f + 16))
        let bitsPerSample = le32(b, f + 20)
        let sampleCount = Int(le64(b, f + 24))
        let blockSize = Int(le32(b, f + 32))
        // "data" 块从 28 + 52 开始
        guard String(decoding: b[80..<84], as: UTF8.self) == "data", channels > 0, rate > 0, blockSize > 0 else { return nil }

        var file = DSDFile(container: .dsf, channels: channels, sampleRate: rate,
                           bytesPerChannel: sampleCount / 8, dataOffset: 92,
                           blockSize: blockSize, lsbFirst: bitsPerSample == 1)
        if metadataOffset > 0, (try? fh.seek(toOffset: UInt64(metadataOffset))) != nil,
           let tag = try? fh.readToEnd(), !tag.isEmpty {
            file.apply(ID3Tag.parse([UInt8](tag), includePicture: includePicture))
        }
        return file
    }

    // MARK: DFF

    private static func readDFF(_ fh: FileHandle, includePicture: Bool) -> DSDFile? {
        guard (try? fh.seek(toOffset: 0)) != nil, let head = try? fh.read(upToCount: 16), head.count == 16,
              String(decoding: head[12..<16], as: UTF8.self) == "DSD " else { return nil }
        let fileEnd = 12 + Int(be64([UInt8](head), 4))

        var file = DSDFile(container: .dff, channels: 0, sampleRate: 0, bytesPerChannel: 0, dataOffset: 0,
                           blockSize: 1, lsbFirst: false)
        var pos = 16
        var dataSize = 0
        while pos + 12 <= fileEnd {
            guard (try? fh.seek(toOffset: UInt64(pos))) != nil, let ch = try? fh.read(upToCount: 12), ch.count == 12 else { break }
            let c = [UInt8](ch)
            let id = String(decoding: c[0..<4], as: UTF8.self)
            let size = Int(be64(c, 4))
            let body = pos + 12
            switch id {
            case "PROP":
                if let data = try? fh.read(upToCount: min(size, 1 << 20)) { file.parseProp([UInt8](data)) }
            case "DSD ":
                file.dataOffset = body
                dataSize = size
            case "DST ":
                file.dataOffset = body
                file.compressed = true
            case "DIIN":
                if let data = try? fh.read(upToCount: min(size, 1 << 20)) { file.parseDIIN([UInt8](data)) }
            case "ID3 ":
                if let data = try? fh.read(upToCount: min(size, 64 << 20)) {
                    file.apply(ID3Tag.parse([UInt8](data), includePicture: includePicture))
                }
            default: break
            }
            pos = body + size + (size & 1)   // 块按偶数字节对齐
        }
        guard file.channels > 0, file.sampleRate > 0, file.dataOffset > 0 else { return nil }
        file.bytesPerChannel = dataSize / file.channels
        return file
    }

    private mutating func parseProp(_ b: [UInt8]) {
        guard b.count >= 4, String(decoding: b[0..<4], as: UTF8.self) == "SND " else { return }
        var p = 4
        while p + 12 <= b.count {
            let id = String(decoding: b[p..<p + 4], as: UTF8.self)
            let size = Int(be64(b, p + 4))
            let body = p + 12
            guard body + size <= b.count else { break }
            switch id {
            case "FS  ": sampleRate = Int(be32(b, body))
            case "CHNL": channels = Int(b[body]) << 8 | Int(b[body + 1])
            case "CMPR": compressed = String(decoding: b[body..<body + 4], as: UTF8.self) != "DSD "
            default: break
            }
            p = body + size + (size & 1)
        }
    }

    private mutating func parseDIIN(_ b: [UInt8]) {
        var p = 0
        while p + 12 <= b.count {
            let id = String(decoding: b[p..<p + 4], as: UTF8.self)
            let size = Int(be64(b, p + 4))
            let body = p + 12
            guard body + size <= b.count else { break }
            if (id == "DITI" || id == "DIAR"), size >= 4 {
                let count = Int(be32(b, body))
                let end = min(body + 4 + count, body + size)
                let text = String(decoding: b[(body + 4)..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                if !text.isEmpty {
                    if id == "DITI", title == nil { title = text }
                    if id == "DIAR", artist == nil { artist = text }
                }
            }
            p = body + size + (size & 1)
        }
    }

    /// ID3 里的值优先（比 DIIN 全）
    private mutating func apply(_ tag: ID3Tag) {
        title = tag.title ?? title
        artist = tag.artist ?? artist
        album = tag.album ?? album
        trackNumber = tag.trackNumber ?? trackNumber
        lyrics = tag.lyrics ?? lyrics
        picture = tag.picture ?? picture
    }
}

// MARK: 字节读取

private func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}
private func le64(_ b: [UInt8], _ i: Int) -> UInt64 {
    UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32
}
private func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
}
private func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
    UInt64(be32(b, i)) << 32 | UInt64(be32(b, i + 4))
}

/// 最简单的 ID3v2（2.3 / 2.4）读取：歌名、歌手、专辑、音轨号、歌词、封面
struct ID3Tag {
    var title: String?
    var artist: String?
    var album: String?
    var trackNumber: Int?
    var lyrics: String?
    var picture: Data?

    static func parse(_ b: [UInt8], includePicture: Bool) -> ID3Tag {
        var tag = ID3Tag()
        guard b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return tag }   // "ID3"
        let version = b[3]
        guard version == 3 || version == 4 else { return tag }
        let flags = b[5]
        let size = syncsafe(b, 6)
        let end = min(b.count, 10 + size)
        var p = 10
        if flags & 0x40 != 0, p + 4 <= end {   // 扩展头
            let ext = version == 4 ? syncsafe(b, p) : Int(be32(b, p)) + 4
            p += ext
        }
        var albumArtist: String?
        while p + 10 <= end {
            let id = String(decoding: b[p..<p + 4], as: UTF8.self)
            guard id.first?.isLetter == true || id.first?.isNumber == true, b[p] != 0 else { break }
            let len = version == 4 ? syncsafe(b, p + 4) : Int(be32(b, p + 4))
            let body = p + 10
            guard len > 0, body + len <= end else { break }
            let frame = Array(b[body..<body + len])
            switch id {
            case "TIT2": tag.title = text(frame)
            case "TPE1": tag.artist = text(frame)
            case "TPE2": albumArtist = text(frame)
            case "TALB": tag.album = text(frame)
            case "TRCK": tag.trackNumber = text(frame).flatMap { Int($0.split(separator: "/").first ?? "") }
            case "USLT": tag.lyrics = lyricsText(frame)
            case "APIC" where includePicture && tag.picture == nil: tag.picture = pictureData(frame)
            default: break
            }
            p = body + len
        }
        if tag.artist == nil { tag.artist = albumArtist }
        return tag
    }

    private static func syncsafe(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i] & 0x7f) << 21 | Int(b[i + 1] & 0x7f) << 14 | Int(b[i + 2] & 0x7f) << 7 | Int(b[i + 3] & 0x7f)
    }

    /// 按编码字节解码一段文字（0 = Latin-1，1 = 带 BOM 的 UTF-16，2 = UTF-16BE，3 = UTF-8）
    private static func decode(_ bytes: ArraySlice<UInt8>, encoding: UInt8) -> String {
        let data = Data(bytes)
        let s: String?
        switch encoding {
        case 1: s = String(data: data, encoding: .utf16)
        case 2: s = String(data: data, encoding: .utf16BigEndian)
        case 3: s = String(data: data, encoding: .utf8)
        default:
            // 很多中文标签其实是 GBK 存在 Latin-1 里：能按 GBK 解就用 GBK
            let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            s = data.contains(where: { $0 >= 0x80 }) ? (String(data: data, encoding: gbk) ?? String(data: data, encoding: .isoLatin1))
                                                    : String(data: data, encoding: .isoLatin1)
        }
        return (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    /// 编码字节后面的字符串结束位置（UTF-16 用两个 0 结束）
    private static func terminator(_ b: [UInt8], from: Int, encoding: UInt8) -> Int {
        var i = from
        if encoding == 1 || encoding == 2 {
            while i + 1 < b.count, !(b[i] == 0 && b[i + 1] == 0) { i += 2 }
            return min(i, b.count)
        }
        while i < b.count, b[i] != 0 { i += 1 }
        return i
    }

    private static func text(_ f: [UInt8]) -> String? {
        guard let enc = f.first else { return nil }
        let s = decode(f[1...], encoding: enc).components(separatedBy: "\0").first ?? ""
        return s.isEmpty ? nil : s
    }

    private static func lyricsText(_ f: [UInt8]) -> String? {
        guard f.count > 4 else { return nil }
        let enc = f[0]
        let descEnd = terminator(f, from: 4, encoding: enc)
        let start = descEnd + ((enc == 1 || enc == 2) ? 2 : 1)
        guard start < f.count else { return nil }
        let s = decode(f[start...], encoding: enc)
        return s.isEmpty ? nil : s
    }

    private static func pictureData(_ f: [UInt8]) -> Data? {
        guard f.count > 4 else { return nil }
        let enc = f[0]
        var i = 1
        while i < f.count, f[i] != 0 { i += 1 }   // MIME 类型
        i += 2                                     // 0 结束符 + 图片类型
        guard i < f.count else { return nil }
        i = terminator(f, from: i, encoding: enc) + ((enc == 1 || enc == 2) ? 2 : 1)   // 描述
        guard i < f.count else { return nil }
        return Data(f[i...])
    }
}
