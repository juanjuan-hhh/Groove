import AVFoundation
import Foundation
import SoundAnalysis

/// 歌词自动对齐：从音频里找出人声「进来」的时刻，算出整首歌词应该提前 / 延后多少秒。
///
/// 1. 把歌解码成 16kHz 单声道，用系统自带的声音分类器每 0.25 秒判断一次「有没有人在唱」（1 秒窗口），
///    得到「在唱」的概率曲线；
/// 2. 找「进歌」的句子（第一句、间奏后的第一句），它们前面没人声，人声开始的那一刻最好认；
///    附近 ±15 秒里每一个人声起点都是一个候选平移量；
/// 3. 每个候选按「歌词句子覆盖的时间里在唱的概率 − 句子外面（前奏、间奏、尾奏）的」打分，
///    支持它的进歌句多加一点分；
/// 4. 最好的候选要明显比隔开 1 秒以上的其他候选好、而且至少两个进歌句（只有一个时要求更明显）互相印证才采用；
///    最后用 0.5 秒小窗口在这些进歌点上再精细测一次，取平均
enum LyricAligner {
    struct Result {
        /// 人声比歌词时间晚多少秒（负数 = 早），歌词偏移应设为 -shift
        var shift: Double
        /// 足够有把握，可以采用
        var reliable: Bool
        /// 互相印证的进歌点数
        var support: Int
        /// 人声听得清不清楚：歌词覆盖的时间里「在唱」概率比外面高多少。太低（伴奏太响盖住人声、
        /// 或者歌词是别的版本）时估计值没有参考价值
        var contrast: Double
        var vocalsClear: Bool { contrast >= 0.3 }
    }

    static let searchRange = 15.0
    /// 「在唱」概率越过中间值的时刻比耳朵听到人声进来要晚一点：Juan 实听两首都慢了约 0.2 秒，统一往前补
    static let perceptualLead = 0.2
    static let sampleRate = 16_000.0
    static let fps = 100.0

    /// 整个流程：解码 → 「在唱」曲线 → 估计。asset 用 AVPlayer 播放的同一个（DSD 也行）
    static func align(asset: AVAsset, lines: [LyricLine]) async -> Result? {
        let starts = sungLines(lines)
        guard starts.count >= 4, let mono = await decode(asset: asset), !Task.isCancelled,
              let vocal = singing(mono) else { return nil }
        return estimate(starts: starts, vocal: vocal) { preciseOnset(mono, near: $0) }
    }

    // MARK: 解码

    /// 用 AVAssetReader 解码成 16kHz 单声道浮点
    static func decode(asset: AVAsset) async -> [Float]? {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: length / 4))
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                               destination: raw.baseAddress! + start * 4)
            }
            if Task.isCancelled { reader.cancelReading(); return nil }
        }
        return reader.status == .completed ? samples : nil
    }

    // MARK: 「在唱」概率

    /// 系统声音分类器「singing」的概率，每 hop 秒一次（window 秒窗口），线性插值成每 10ms 一个值。
    /// range：只分析这一段（采样点下标）
    static func singing(_ x: [Float], hop: Double = 0.25, window: Double = 1, range: Range<Int>? = nil) -> [Float]? {
        let first = max(0, range?.lowerBound ?? 0), last = min(x.count, range?.upperBound ?? x.count)
        let frames = last - first
        guard frames > Int(sampleRate * window),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        request.windowDuration = CMTime(seconds: window, preferredTimescale: 1000)
        request.overlapFactor = 1 - hop / window
        final class Collector: NSObject, SNResultsObserving {
            var points: [(Double, Float)] = []
            func request(_ request: SNRequest, didProduce result: SNResult) {
                guard let r = result as? SNClassificationResult else { return }
                let p = max(r.classification(forIdentifier: "singing")?.confidence ?? 0,
                            r.classification(forIdentifier: "choir_singing")?.confidence ?? 0)
                points.append((r.timeRange.start.seconds + r.timeRange.duration.seconds / 2, Float(p)))
            }
        }
        let collector = Collector()
        let analyzer = SNAudioStreamAnalyzer(format: format)
        guard (try? analyzer.add(request, withObserver: collector)) != nil else { return nil }
        let chunk = Int(sampleRate) * 10
        var position = 0
        while position < frames {
            let count = min(chunk, frames - position)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
            buffer.frameLength = AVAudioFrameCount(count)
            x.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + first + position, count: count)
            }
            analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(position))
            position += count
        }
        analyzer.completeAnalysis()
        let points = collector.points.sorted { $0.0 < $1.0 }
        guard points.count > 2 else { return nil }
        let n = Int(Double(frames) / sampleRate * fps)
        var out = [Float](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            let t = Double(i) / fps
            while j + 1 < points.count && points[j + 1].0 <= t { j += 1 }
            if t <= points[0].0 { out[i] = points[0].1; continue }
            if j + 1 >= points.count { out[i] = points[points.count - 1].1; continue }
            let (t0, v0) = points[j], (t1, v1) = points[j + 1]
            out[i] = v0 + (v1 - v0) * Float((t - t0) / (t1 - t0))
        }
        return out
    }

    /// 在 time 附近用 0.5 秒窗口、每 50ms 看一次「在唱」概率，找从低到高越过中间值的时刻
    static func preciseOnset(_ x: [Float], near time: Double) -> Double? {
        let start = time - 1.5
        guard start > 0, let p = singing(x, hop: 0.05, window: 0.5,
                                         range: Int(start * sampleRate)..<Int((time + 1.0) * sampleRate)) else { return nil }
        let c = Int(1.5 * fps)
        guard p.count > c + 50 else { return nil }
        let low = p[max(0, c - 100)..<c].min() ?? 0, high = p[c..<min(p.count, c + 100)].max() ?? 0
        guard high - low > 0.15 else { return nil }
        let threshold = low + (high - low) * 0.5
        var best: Double?
        for k in 1..<p.count where p[k - 1] < threshold && p[k] >= threshold {
            let t = start + (Double(k - 1) + Double((threshold - p[k - 1]) / max(p[k] - p[k - 1], 1e-6))) / fps
            if best == nil || abs(t - time) < abs(best! - time) { best = t }
        }
        return best
    }

    // MARK: 估计平移量

    /// 真正在唱的句子的开始时间（去掉「作词 : xxx」「歌手 - 歌名」这种开头信息）
    static func sungLines(_ lines: [LyricLine]) -> [Double] {
        lines.compactMap { line in
            guard let t = line.time else { return nil }
            let text = line.text
            if text.contains(":") || text.contains("：") { return nil }
            if t < 20 && text.contains(" - ") { return nil }
            return t
        }
    }

    /// vocal：每 10ms 的「在唱」概率；refine：给一个大概的人声起点，返回更精确的时刻
    static func estimate(starts: [Double], vocal v: [Float], refine: ((Double) -> Double?)? = nil) -> Result? {
        guard starts.count >= 4, v.count > Int(fps * 10) else { return nil }
        let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }.filter { $0 > 0.5 }.sorted()
        let typical = gaps.isEmpty ? 4 : min(8, max(2, gaps[gaps.count / 2]))

        // 每句覆盖到下一句开始，最长一般句长的 1.5 倍
        var spans: [(Int, Int)] = []
        for (i, s) in starts.enumerated() {
            let next = i + 1 < starts.count ? starts[i + 1] : s + typical
            spans.append((Int(s * fps), Int(min(next, s + typical * 1.5) * fps)))
        }
        var prefix = [Double](repeating: 0, count: v.count + 1)
        for i in 0..<v.count { prefix[i + 1] = prefix[i] + Double(v[i]) }
        /// 歌词整体平移 shift 秒后：句子里「在唱」的平均概率 − 句子外面的
        func contrast(_ shift: Double) -> Double {
            let d = Int((shift * fps).rounded())
            var inside = 0.0, count = 0
            for (a, b) in spans {
                let a2 = min(max(a + d, 0), v.count), b2 = min(max(b + d, 0), v.count)
                if b2 > a2 { inside += prefix[b2] - prefix[a2]; count += b2 - a2 }
            }
            let outside = v.count - count
            guard count > 0, outside > 0 else { return -1 }
            return inside / Double(count) - (prefix[v.count] - inside) / Double(outside)
        }

        // 人声「进来」的时刻：「在唱」概率升过 0.5，而且之前 0.75 秒都低于 0.5
        var onsets: [Double] = []
        for k in Int(fps)..<v.count where v[k - 1] < 0.5 && v[k] >= 0.5 {
            guard (v[(k - Int(fps * 0.75))..<k].max() ?? 1) < 0.5 else { continue }
            let frac = Double((0.5 - v[k - 1]) / max(v[k] - v[k - 1], 1e-6))
            onsets.append((Double(k - 1) + frac) / fps)
        }
        // 「进歌」的句子：第一句、间奏后的第一句
        let entries = starts.enumerated().filter { i, s in i == 0 || s - starts[i - 1] >= max(typical * 2, 6) }.map(\.element)
        let tolerance = 0.3
        let candidates: [[Double]] = entries.map { s in onsets.filter { abs($0 - s) <= searchRange }.map { $0 - s } }

        var scored: [(shift: Double, votes: Int, contrast: Double)] = []
        for c in candidates.flatMap({ $0 }) {
            let votes = candidates.filter { $0.contains { abs($0 - c) <= tolerance } }.count
            scored.append((c, votes, contrast(c)))
        }
        let ranked = scored.sorted { $0.contrast + 0.01 * Double($0.votes) > $1.contrast + 0.01 * Double($1.votes) }
        guard let top = ranked.first else { return nil }
        // 隔开 1 秒以上的次好候选（副歌重复、句子间隔一样时会出现几乎一样好的另一个位置）
        let rival = ranked.first { abs($0.shift - top.shift) > 1 }?.contrast ?? -1

        // 支持它的每个进歌点再精细测一次
        var support: [Double] = []
        for (s, cands) in zip(entries, candidates) {
            guard let d = cands.min(by: { abs($0 - top.shift) < abs($1 - top.shift) }), abs(d - top.shift) <= tolerance else { continue }
            if let precise = refine?(s + d).map({ $0 - s }), abs(precise - d) < 0.6 { support.append(precise) } else { support.append(d) }
        }
        guard !support.isEmpty else { return nil }
        let sorted = support.sorted()
        let median = sorted[sorted.count / 2]
        let close = support.filter { abs($0 - median) <= 0.25 }
        let shift = close.reduce(0, +) / Double(close.count) - perceptualLead

        // 可信：整体覆盖够好、明显比别的位置好；至少两个进歌点互相印证（只有一个时要求更明显）
        let margin = top.contrast - rival
        let reliable = top.contrast >= 0.15
            && (top.votes >= 2 ? (margin >= 0.03 && close.count >= 2) : (margin >= 0.08 && top.contrast >= 0.3))
        if ProcessInfo.processInfo.environment["ALIGN_DEBUG"] != nil {
            print(String(format: "  entries %d votes %d contrast %.2f margin %.2f support %@ -> %.2f %@", entries.count, top.votes,
                         top.contrast, margin, support.map { String(format: "%.2f", $0) }.joined(separator: " "), shift, reliable ? "OK" : "--"))
        }
        return Result(shift: shift, reliable: reliable, support: close.count, contrast: top.contrast)
    }
}
