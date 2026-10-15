import Foundation

/// 直接读取 FLAC 文件头里的信息：采样率、位深、时长、Vorbis 标签（歌名、歌手、歌词等）和内嵌封面。
struct FLACInfo {
    var sampleRate: Double = 0
    var bitDepth = 0
    var duration: Double = 0
    var tags: [String: String] = [:]   // key 统一为大写，例如 TITLE、ARTIST、LYRICS
    var picture: Data?
}

enum FLACParser {
    static func read(url: URL, includePicture: Bool) -> FLACInfo? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        guard let head = try? fh.read(upToCount: 10), head.count == 10 else { return nil }
        let h = [UInt8](head)
        var start: UInt64 = 0
        // 有些 FLAC 文件前面带 ID3 标签，先跳过
        if h[0] == 0x49, h[1] == 0x44, h[2] == 0x33 {
            let size = (UInt64(h[6] & 0x7f) << 21) | (UInt64(h[7] & 0x7f) << 14)
                | (UInt64(h[8] & 0x7f) << 7) | UInt64(h[9] & 0x7f)
            start = 10 + size + ((h[5] & 0x10) != 0 ? 10 : 0)
        }
        guard (try? fh.seek(toOffset: start)) != nil,
              let magic = try? fh.read(upToCount: 4), [UInt8](magic) == [0x66, 0x4C, 0x61, 0x43] // "fLaC"
        else { return nil }

        var info = FLACInfo()
        var pictureType = -1
        var isLast = false
        while !isLast {
            guard let headerData = try? fh.read(upToCount: 4), headerData.count == 4 else { break }
            let bh = [UInt8](headerData)
            isLast = (bh[0] & 0x80) != 0
            let type = bh[0] & 0x7f
            let length = Int(bh[1]) << 16 | Int(bh[2]) << 8 | Int(bh[3])

            let wantBlock = type == 0 || type == 4 || (type == 6 && includePicture)
            if !wantBlock {
                guard let pos = try? fh.offset(), (try? fh.seek(toOffset: pos + UInt64(length))) != nil else { break }
                continue
            }
            guard let blockData = try? fh.read(upToCount: length), blockData.count == length else { break }
            let block = [UInt8](blockData)

            switch type {
            case 0: parseStreamInfo(block, into: &info)
            case 4: info.tags = parseVorbisComments(block)
            case 6:
                if let pic = parsePicture(block) {
                    // 优先使用"封面"类型（3）的图片
                    if info.picture == nil || (pic.type == 3 && pictureType != 3) {
                        info.picture = pic.data
                        pictureType = pic.type
                    }
                }
            default: break
            }
        }
        return info
    }

    private static func parseStreamInfo(_ b: [UInt8], into info: inout FLACInfo) {
        guard b.count >= 18 else { return }
        let sampleRate = (Int(b[10]) << 12) | (Int(b[11]) << 4) | (Int(b[12]) >> 4)
        let bits = ((Int(b[12]) & 0x01) << 4 | (Int(b[13]) >> 4)) + 1
        let totalSamples = (UInt64(b[13] & 0x0f) << 32) | (UInt64(b[14]) << 24)
            | (UInt64(b[15]) << 16) | (UInt64(b[16]) << 8) | UInt64(b[17])
        info.sampleRate = Double(sampleRate)
        info.bitDepth = bits
        if sampleRate > 0 { info.duration = Double(totalSamples) / Double(sampleRate) }
    }

    private static func parseVorbisComments(_ b: [UInt8]) -> [String: String] {
        var i = 0
        func u32() -> Int? {
            guard i + 4 <= b.count else { return nil }
            let v = Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
            i += 4
            return v
        }
        guard let vendorLength = u32(), i + vendorLength <= b.count else { return [:] }
        i += vendorLength
        guard let count = u32() else { return [:] }

        var tags: [String: String] = [:]
        for _ in 0..<count {
            guard let len = u32(), i + len <= b.count else { break }
            let entry = String(decoding: b[i..<(i + len)], as: UTF8.self)
            i += len
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = entry[..<eq].uppercased()
            let value = String(entry[entry.index(after: eq)...])
            if let existing = tags[key] {
                if key == "ARTIST" { tags[key] = existing + " / " + value }
            } else {
                tags[key] = value
            }
        }
        return tags
    }

    private static func parsePicture(_ b: [UInt8]) -> (type: Int, data: Data)? {
        var i = 0
        func u32() -> Int? {
            guard i + 4 <= b.count else { return nil }
            let v = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            i += 4
            return v
        }
        guard let type = u32(), let mimeLength = u32(), i + mimeLength <= b.count else { return nil }
        i += mimeLength
        guard let descLength = u32(), i + descLength <= b.count else { return nil }
        i += descLength
        i += 16 // width, height, depth, colors
        guard let dataLength = u32(), dataLength > 0, i + dataLength <= b.count else { return nil }
        return (type, Data(b[i..<(i + dataLength)]))
    }
}
