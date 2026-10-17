import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// 把 DSD 文件实时变成一个虚拟的 WAV 交给 AVPlayer 播放（进度、跳转、系统「正在播放」都和普通歌一样）：
/// - PCM：DSD 经过低通滤波、抽取成 176.4kHz 32 位浮点（DSD 满幅 = PCM 满幅，所以 0 dB SACD 约等于 −6 dBFS，留了余量）
/// - DoP：不解码，每 16 个 DSD 采样加一个 0x05 / 0xFA 标记字节打包成 24 位 PCM（DSD64 → 176.4kHz），解码器认出标记后按 DSD 播放。
///   只有独占、音量 100%、声卡用 24/32 位整数且采样率完全一致时才原样到达解码器
final class DSDDecoder: @unchecked Sendable {
    enum Mode: Sendable, Equatable { case pcm, dop }

    /// PCM 模式统一输出 176.4kHz
    static let pcmRate = 176_400

    let file: DSDFile
    let mode: Mode
    let outputRate: Int
    let frameCount: Int
    let bytesPerFrame: Int
    let header: [UInt8]
    var totalLength: Int { header.count + frameCount * bytesPerFrame }

    private let fd: Int32
    /// 每个输出帧用掉每个声道多少个 DSD 字节
    private let step: Int
    /// 滤波器覆盖多少个 DSD 字节，以及每个字节位置的 256 种取值对应的滤波结果
    private let taps: Int
    private let table: [Float]

    init?(url: URL, file: DSDFile, mode: Mode) {
        guard !file.compressed, file.channels > 0, file.sampleRate >= 2_822_400 else { return nil }
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        self.fd = fd
        self.file = file
        self.mode = mode
        switch mode {
        case .pcm:
            outputRate = Self.pcmRate
            step = file.sampleRate / Self.pcmRate / 8   // DSD64: 2，DSD128: 4……
            bytesPerFrame = 4 * file.channels
            taps = 32 * step
            table = Self.makeTable(taps: taps, inputRate: Double(file.sampleRate))
        case .dop:
            outputRate = file.sampleRate / 16
            step = 2
            bytesPerFrame = 3 * file.channels
            taps = 0
            table = []
        }
        // WAV 的长度字段只有 32 位，超出的部分截掉（双声道 PCM 约 50 分钟）
        let maxFrames = (Int(UInt32.max) - 64) / bytesPerFrame
        frameCount = min(file.bytesPerChannel / step, maxFrames)
        header = Self.wavHeader(channels: file.channels, rate: outputRate, float: mode == .pcm,
                                dataBytes: frameCount * bytesPerFrame)
    }

    deinit { close(fd) }

    // MARK: 滤波器

    /// Blackman 窗 sinc 低通（截止 45kHz），按每 8 个系数一组，预先算好一个字节 256 种取值的和
    private static func makeTable(taps: Int, inputRate: Double) -> [Float] {
        let n = taps * 8
        let fc = 45_000 / inputRate
        var h = [Double](repeating: 0, count: n)
        let mid = Double(n - 1) / 2
        for i in 0..<n {
            let x = Double(i) - mid
            let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(n - 1))
            h[i] = sinc * w
        }
        let sum = h.reduce(0, +)
        var table = [Float](repeating: 0, count: taps * 256)
        for g in 0..<taps {
            for v in 0..<256 {
                var acc = 0.0
                for k in 0..<8 {   // 字节里最高位是最早的采样
                    let bit = (v >> (7 - k)) & 1
                    acc += h[g * 8 + k] / sum * (bit == 1 ? 1 : -1)
                }
                table[g * 256 + v] = Float(acc)
            }
        }
        return table
    }

    // MARK: 读原始 DSD

    /// 字节位反转（DSF 是最早的采样在最低位，统一成最高位）
    private static let reversed: [UInt8] = (0..<256).map { v in
        var r = 0
        for k in 0..<8 where v & (1 << k) != 0 { r |= 1 << (7 - k) }
        return UInt8(r)
    }

    /// 读每个声道第 start ..< start+count 个 DSD 字节，最早的采样在最高位；超出文件的部分填 DSD 静音（0x69）
    private func readChannels(start: Int, count: Int) -> [[UInt8]] {
        var out = [[UInt8]](repeating: [UInt8](repeating: 0x69, count: count), count: file.channels)
        let lo = max(start, 0), hi = min(start + count, file.bytesPerChannel)
        guard lo < hi else { return out }
        let ch = file.channels, bs = file.blockSize
        // 一次读出覆盖这段的连续文件区域
        let firstBlock = lo / bs, lastBlock = (hi - 1) / bs
        let regionStart = file.dataOffset + firstBlock * bs * ch
        let regionLength = (lastBlock - firstBlock + 1) * bs * ch
        var region = [UInt8](repeating: 0x69, count: regionLength)
        let got = region.withUnsafeMutableBytes { pread(fd, $0.baseAddress, regionLength, off_t(regionStart)) }
        guard got > 0 else { return out }
        let rev = file.lsbFirst
        for c in 0..<ch {
            out[c].withUnsafeMutableBufferPointer { dst in
                region.withUnsafeBufferPointer { src in
                    for i in lo..<hi {
                        let local = i - firstBlock * bs
                        let offset = (local / bs) * bs * ch + c * bs + local % bs
                        guard offset < got else { continue }
                        let v = src[offset]
                        dst[i - start] = rev ? Self.reversed[Int(v)] : v
                    }
                }
            }
        }
        return out
    }

    // MARK: 输出

    /// 虚拟 WAV 文件里 offset 开始的 length 个字节
    func bytes(offset: Int, length: Int) -> Data {
        var data = Data()
        let end = min(offset + length, totalLength)
        guard offset < end else { return data }
        data.reserveCapacity(end - offset)
        if offset < header.count {
            data.append(contentsOf: header[offset..<min(header.count, end)])
        }
        let audioStart = max(offset, header.count) - header.count
        let audioEnd = end - header.count
        guard audioStart < audioEnd else { return data }
        let firstFrame = audioStart / bytesPerFrame
        let lastFrame = (audioEnd - 1) / bytesPerFrame
        let frames = render(from: firstFrame, count: lastFrame - firstFrame + 1)
        let skip = audioStart - firstFrame * bytesPerFrame
        data.append(frames[skip..<(skip + audioEnd - audioStart)])
        return data
    }

    /// 从第 first 帧开始渲染 count 帧（交错排列）
    private func render(from first: Int, count: Int) -> Data {
        let ch = file.channels
        var out = Data(count: count * bytesPerFrame)
        switch mode {
        case .pcm:
            // 第 n 帧以第 n*step 个字节为中心，前后各 taps/2 个字节
            let half = taps / 2
            let raw = readChannels(start: first * step - half, count: count * step + taps)
            out.withUnsafeMutableBytes { buf in
                let dst = buf.bindMemory(to: Float.self)
                table.withUnsafeBufferPointer { tab in
                    for c in 0..<ch {
                        raw[c].withUnsafeBufferPointer { src in
                            for n in 0..<count {
                                var acc: Float = 0
                                let base = n * step
                                for g in 0..<taps {
                                    acc += tab[g &* 256 &+ Int(src[base &+ g])]
                                }
                                dst[n * ch + c] = acc
                            }
                        }
                    }
                }
            }
        case .dop:
            let raw = readChannels(start: first * 2, count: count * 2)
            out.withUnsafeMutableBytes { buf in
                let dst = buf.bindMemory(to: UInt8.self)
                for n in 0..<count {
                    // 标记按绝对帧号交替，跳转后也不会乱
                    let marker: UInt8 = (first + n) & 1 == 0 ? 0x05 : 0xFA
                    for c in 0..<ch {
                        let o = (n * ch + c) * 3
                        dst[o] = raw[c][n * 2 + 1]   // 小端：低字节是后 8 个采样
                        dst[o + 1] = raw[c][n * 2]
                        dst[o + 2] = marker
                    }
                }
            }
        }
        return out
    }

    private static func wavHeader(channels: Int, rate: Int, float: Bool, dataBytes: Int) -> [UInt8] {
        var h: [UInt8] = []
        func u16(_ v: Int) { h += [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        func u32(_ v: Int) { h += [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
        let bits = float ? 32 : 24
        let blockAlign = channels * bits / 8
        h += Array("RIFF".utf8); u32(36 + 2 + dataBytes)
        h += Array("WAVE".utf8)
        h += Array("fmt ".utf8); u32(18)
        u16(float ? 3 : 1); u16(channels); u32(rate); u32(rate * blockAlign); u16(blockAlign); u16(bits); u16(0)
        h += Array("data".utf8); u32(dataBytes)
        return h
    }
}

/// AVPlayer 通过自定义网址（groove-dsd://）来要数据，这里按要的范围现算现给
final class DSDResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "groove-dsd"

    let decoder: DSDDecoder
    private let queue = DispatchQueue(label: "groove.dsd", qos: .userInitiated)

    init(decoder: DSDDecoder) {
        self.decoder = decoder
    }

    /// 给 AVPlayer 用的资源（网址后缀 .wav，让它按 WAV 解析）
    func makeAsset() -> AVURLAsset {
        var comps = URLComponents()
        comps.scheme = Self.scheme
        comps.host = "local"
        comps.path = "/" + UUID().uuidString + ".wav"
        let asset = AVURLAsset(url: comps.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url?.scheme == Self.scheme else { return false }
        if let info = request.contentInformationRequest {
            info.contentType = UTType.wav.identifier
            info.contentLength = Int64(decoder.totalLength)
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let start = Int(dataRequest.requestedOffset)
        let end = dataRequest.requestsAllDataToEndOfResource
            ? decoder.totalLength
            : min(decoder.totalLength, start + dataRequest.requestedLength)
        // 在别的线程分块算、分块给；AVPlayer 取消了（跳转、换歌）就停
        let decoder = decoder
        DispatchQueue.global(qos: .userInitiated).async {
            var offset = Int(dataRequest.currentOffset)
            let chunk = 256 * 1024
            while offset < end {
                if request.isCancelled { return }
                let data = decoder.bytes(offset: offset, length: min(chunk, end - offset))
                if data.isEmpty { break }
                dataRequest.respond(with: data)
                offset += data.count
            }
            if !request.isCancelled { request.finishLoading() }
        }
        return true
    }
}
