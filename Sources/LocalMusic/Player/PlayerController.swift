import AppKit
import AVFoundation
import MediaPlayer
import Observation

enum RepeatMode: Int, CaseIterable {
    case all, one, off

    var symbol: String {
        switch self {
        case .all: return "repeat"
        case .one: return "repeat.1"
        case .off: return "arrow.forward.to.line"
        }
    }

    var label: String {
        switch self {
        case .all: return "列表循环"
        case .one: return "单曲循环"
        case .off: return "顺序播放（播完停止）"
        }
    }
}

/// 实际交给 AVPlayer 的是什么
enum PlaybackStream: Equatable, Sendable {
    /// 文件本身（FLAC、MP3……）
    case file
    /// DSD 转成的 PCM；dopProblem：选了 DoP 但用不了的原因
    case dsdPCM(rate: Double, dopProblem: String?)
    /// DoP 打包的 DSD
    case dop(rate: Double)
}

enum LyricsState: Equatable {
    case idle, loading, loaded, notFound
}

/// 播放器：播放队列、随机/循环、进度、睡眠定时、当前歌曲的歌词和封面
@MainActor
@Observable
final class PlayerController {
    private(set) var queue: [Track] = [] { didSet { sessionDirty = true } }
    private(set) var index = 0 { didSet { sessionDirty = true } }
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0 { didSet { refreshLyricIndex() } }
    private(set) var duration: Double = 0
    private(set) var shuffle = false { didSet { sessionDirty = true } }
    private(set) var repeatMode: RepeatMode = .all { didSet { sessionDirty = true } }
    var showNowPlaying = false
    var showLyrics = false
    /// 正在调整歌词时间：歌词页下方显示「提前 / 延后」按钮（在 ⋯ 菜单里开、关）
    var adjustingLyrics = false

    private(set) var lyrics: [LyricLine] = [] { didSet { refreshLyricIndex() } }
    private(set) var lyricsState: LyricsState = .idle
    private(set) var lyricsSource: LyricsSource?
    /// 歌词时间调整（秒）：正数表示歌词提前出现，负数表示延后。每首歌单独保存
    private(set) var lyricOffset: Double = 0 { didSet { refreshLyricIndex() } }
    private(set) var isFetchingOnline = false
    /// 不为 nil 时显示「联网搜索」面板
    var searchTarget: Track?

    private(set) var sleepDeadline: Date?
    private(set) var stopAfterCurrent = false

    @ObservationIgnored private var originalQueue: [Track] = []
    private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var sleepTimer: Timer?
    @ObservationIgnored private var extrasTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingArtwork: NSImage?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    /// 音频链路面板用：播放器音量（1 = 100%，不做数字音量）和正在输出到的设备（nil = 系统默认）
    var outputVolume: Float { player.volume }
    var outputDeviceUID: String? { player.audioOutputDeviceUniqueID }
    private(set) var stream: PlaybackStream = .file
    /// DSD 的虚拟 WAV 数据来源（AVPlayer 只弱引用它）
    @ObservationIgnored private var dsdLoader: DSDResourceLoader?

    var upNext: Track? {
        guard !queue.isEmpty else { return nil }
        if repeatMode == .one { return current }
        if index + 1 < queue.count { return queue[index + 1] }
        return repeatMode == .all ? queue.first : nil
    }

    var sleepActive: Bool { sleepDeadline != nil || stopAfterCurrent }

    /// 当前唱到第几行。播放时间每 0.25 秒更新一次，但只有换行时才改这个值，
    /// 所以歌词页、底部播放条那句歌词不会每 0.25 秒整个重画一遍
    private(set) var currentLyricIndex: Int?

    /// 系统「正在播放」（控制中心、菜单栏）上显示到第几句。系统收到更新后要过一会儿才显示，所以提前 0.5 秒换句（和 iPhone 版一样）
    @ObservationIgnored private var lockLyricIndex: Int? {
        didSet { if lockLyricIndex != oldValue, AppSettings.lockScreenLyrics { updateNowPlayingInfo() } }
    }
    private static let lockScreenLead = 0.5

    /// 正在拖动进度条：拖到的时间（松手前不真的跳过去）。歌词按它来亮，方便看拖到了哪一句
    var scrubTime: Double? { didSet { refreshLyricIndex() } }

    private func refreshLyricIndex() {
        let index = LRCParser.index(in: lyrics, at: (scrubTime ?? currentTime) + 0.15 + lyricOffset)
        if index != currentLyricIndex { currentLyricIndex = index }
        let lockIndex = LRCParser.index(in: lyrics, at: (scrubTime ?? currentTime) + 0.15 + lyricOffset + Self.lockScreenLead)
        if lockIndex != lockLyricIndex { lockLyricIndex = lockIndex }
    }

    // MARK: 歌词时间调整

    static let lyricOffsetStep = 0.5

    var hasSyncedLyrics: Bool { lyrics.first?.time != nil }

    /// 例如 "歌词提前 0.5s"、"歌词延后 1.0s"、"歌词已同步"
    var lyricOffsetLabel: String {
        if lyricOffset == 0 { return "歌词已同步" }
        return String(format: "歌词%@ %.1fs", lyricOffset > 0 ? "提前" : "延后", abs(lyricOffset))
    }
    private static let lyricOffsetsKey = "lyricOffsets"

    /// 歌词提前（正数）或延后（负数）调整，每次 0.5 秒
    func adjustLyricOffset(by delta: Double) {
        setLyricOffset(lyricOffset + delta)
    }

    func resetLyricOffset() {
        setLyricOffset(0)
    }

    /// 点某一行歌词时跳到的位置（扣掉调整量）
    func seek(toLyric time: Double) {
        seek(to: time - lyricOffset)
    }

    /// 调整歌词时点了某一句：让这一句正好在「现在」亮起来（自动算出提前 / 延后多少秒）
    func alignLyric(at lineTime: Double) {
        setLyricOffset(lineTime - currentTime - 0.15)
    }

    // MARK: 歌词自动对齐

    enum AlignState: Equatable {
        case idle
        case running
        /// 结果提示，例如「已对齐：歌词延后 0.8s」「没把握，未修改」
        case done(String)
    }

    private(set) var alignState: AlignState = .idle
    /// 自动对齐之前的偏移（「撤销」用），没有可撤销的时为 nil
    private(set) var alignUndo: Double?
    /// 没把握时的估计值（可以手动选择「仍然使用」）
    private(set) var alignGuess: Double?
    @ObservationIgnored private var alignTask: Task<Void, Never>?

    /// 从音频里找人声进来的时刻，算出整首歌词该提前 / 延后多少（见 LyricAligner），有把握才改
    func autoAlignLyrics() {
        guard let track = current, hasSyncedLyrics, alignState != .running else { return }
        let lines = lyrics
        alignState = .running
        alignGuess = nil
        alignTask?.cancel()
        alignTask = Task { [weak self] in
            // DSD 用和播放一样的虚拟 WAV（转成 PCM）来分析
            var loader: DSDResourceLoader?
            let asset: AVAsset
            if track.isDSD, let file = DSDFile.read(url: track.url),
               let decoder = DSDDecoder(url: track.url, file: file, mode: .pcm) {
                loader = DSDResourceLoader(decoder: decoder)
                asset = loader!.makeAsset()
            } else {
                asset = AVURLAsset(url: track.url)
            }
            let result = await Task.detached(priority: .userInitiated) {
                await LyricAligner.align(asset: asset, lines: lines)
            }.value
            withExtendedLifetime(loader) {}
            guard let self, !Task.isCancelled, self.current?.id == track.id else { return }
            guard let result else {
                self.alignState = .done("没找到足够的人声，未修改")
                return
            }
            let offset = (-result.shift * 10).rounded() / 10
            guard result.reliable else {
                // 人声都听不清时，估计值基本是乱猜，不给出来免得误导
                guard result.vocalsClear else {
                    self.alignState = .done("人声被伴奏盖住或歌词版本不同，没法自动对齐，请手动调整")
                    return
                }
                self.alignGuess = offset
                self.alignState = .done("没把握，未修改（估计" + Self.offsetText(offset) + "）")
                return
            }
            let before = self.lyricOffset
            self.setLyricOffset(offset)
            self.alignUndo = before == offset ? nil : before
            self.alignState = .done(before == offset ? "已经是对齐的（" + Self.offsetText(offset) + "）"
                                                     : "已对齐：" + Self.offsetText(offset))
        }
    }

    /// 没把握时仍然使用估计值
    func applyAlignGuess() {
        guard let guess = alignGuess else { return }
        alignUndo = lyricOffset
        setLyricOffset(guess)
        alignGuess = nil
        alignState = .done("已使用估计：" + Self.offsetText(guess))
    }

    func undoAutoAlign() {
        guard let undo = alignUndo else { return }
        setLyricOffset(undo)
        alignUndo = nil
        alignState = .done("已撤销，恢复为" + Self.offsetText(undo))
    }

    private func resetAlignState() {
        alignTask?.cancel()
        alignTask = nil
        alignState = .idle
        alignUndo = nil
        alignGuess = nil
    }

    /// 0.8 → "歌词提前 0.8s"，0 → "不偏移"
    private static func offsetText(_ offset: Double) -> String {
        if abs(offset) < 0.05 { return "不偏移" }
        return String(format: "歌词%@ %.1fs", offset > 0 ? "提前" : "延后", abs(offset))
    }

    private func setLyricOffset(_ value: Double) {
        guard let track = current else { return }
        let rounded = (value * 10).rounded() / 10   // 精确到 0.1 秒，避免浮点误差累积
        lyricOffset = rounded
        var all = UserDefaults.standard.dictionary(forKey: Self.lyricOffsetsKey) as? [String: Double] ?? [:]
        all[track.path] = rounded == 0 ? nil : rounded
        UserDefaults.standard.set(all, forKey: Self.lyricOffsetsKey)
    }

    private static func savedLyricOffset(for track: Track) -> Double {
        (UserDefaults.standard.dictionary(forKey: lyricOffsetsKey) as? [String: Double])?[track.path] ?? 0
    }

    init() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, item === self.player.currentItem else { return }
                self.trackDidEnd()
            }
        }
        setupRemoteCommands()
        ExclusiveOutput.shared.configChanged = { [weak self] in self?.outputSettingsChanged() ?? false }
        restoreSession()
    }

    // MARK: 上次播放（退出后下次打开还是这首歌、这个位置，暂停着）

    /// 播放队列、第几首、随机 / 循环存成文件（换歌、改队列时写）；播放位置单独存（播放时每 5 秒、暂停、退出时写），
    /// 这样就算闪退也最多差几秒
    private struct SavedSession: Codable {
        var queue: [Track]
        var originalQueue: [Track]
        var index: Int
        var shuffle: Bool
        var repeatMode: Int
    }
    private static let sessionURL = AppPaths.support.appendingPathComponent("last-session.json")
    private static let sessionPathKey = "lastSessionPath"
    private static let sessionTimeKey = "lastSessionTime"
    @ObservationIgnored private var sessionDirty = false
    @ObservationIgnored private var lastSavedTime: Double = 0
    /// 刚恢复、还没真正跳到上次位置时记着，免得进度先被报成 0
    @ObservationIgnored private var pendingRestoreTime: Double?

    /// 保存播放队列和位置（退出时 AppDelegate 也会调）
    func saveSession() {
        if sessionDirty { saveQueue() }
        savePosition()
    }

    private func saveQueue() {
        sessionDirty = false
        guard current != nil else {
            try? FileManager.default.removeItem(at: Self.sessionURL)
            return
        }
        let session = SavedSession(queue: queue, originalQueue: originalQueue, index: index,
                                   shuffle: shuffle, repeatMode: repeatMode.rawValue)
        if let data = try? JSONEncoder().encode(session) { try? data.write(to: Self.sessionURL, options: .atomic) }
    }

    private func savePosition() {
        let time = pendingRestoreTime ?? currentTime
        lastSavedTime = time
        UserDefaults.standard.set(current?.path, forKey: Self.sessionPathKey)
        UserDefaults.standard.set(time, forKey: Self.sessionTimeKey)
    }

    private func restoreSession() {
        defer { sessionDirty = false }
        guard let data = try? Data(contentsOf: Self.sessionURL),
              let session = try? JSONDecoder().decode(SavedSession.self, from: data),
              session.queue.indices.contains(session.index) else { return }
        let fm = FileManager.default
        let track = session.queue[session.index]
        // 上次那首歌的文件不在了：就当没在播放
        guard fm.fileExists(atPath: track.path) else { return }
        queue = session.queue.filter { fm.fileExists(atPath: $0.path) }
        originalQueue = session.originalQueue.filter { fm.fileExists(atPath: $0.path) }
        index = queue.firstIndex { $0.id == track.id } ?? 0
        shuffle = session.shuffle
        repeatMode = RepeatMode(rawValue: session.repeatMode) ?? .all
        load(autoplay: false)
        // 不放歌就不占着独占的声卡（和暂停一样，过一会儿还回去）
        ExclusiveOutput.shared.paused()
        let defaults = UserDefaults.standard
        let time = defaults.string(forKey: Self.sessionPathKey) == track.path ? defaults.double(forKey: Self.sessionTimeKey) : 0
        if time > 1, time < track.duration - 1 {
            seek(to: time)
            pendingRestoreTime = time
        }
        lastSavedTime = time
    }

    // MARK: 播放队列

    func play(_ tracks: [Track], startAt start: Int = 0) {
        guard tracks.indices.contains(start) else { return }
        originalQueue = tracks
        if shuffle {
            var rest = tracks
            let first = rest.remove(at: start)
            queue = [first] + rest.shuffled()
            index = 0
        } else {
            queue = tracks
            index = start
        }
        load(autoplay: true)
    }

    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        shuffle = true
        play(tracks, startAt: Int.random(in: tracks.indices))
    }

    func playNext(_ track: Track) {
        guard current != nil else { play([track]); return }
        queue.insert(track, at: index + 1)
        if let cur = current, let i = originalQueue.firstIndex(where: { $0.id == cur.id }) {
            originalQueue.insert(track, at: i + 1)
        } else {
            originalQueue.append(track)
        }
    }

    func addToQueue(_ track: Track) {
        guard current != nil else { play([track]); return }
        queue.append(track)
        originalQueue.append(track)
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        load(autoplay: true)
    }

    func removeFromQueue(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        let removed = queue.remove(at: i)
        if i < index { index -= 1 }
        if let j = originalQueue.firstIndex(where: { $0.id == removed.id }) { originalQueue.remove(at: j) }
    }

    func toggleShuffle() {
        shuffle.toggle()
        guard let cur = current else { return }
        if shuffle {
            var rest = originalQueue
            if let i = rest.firstIndex(where: { $0.id == cur.id }) { rest.remove(at: i) }
            queue = [cur] + rest.shuffled()
            index = 0
        } else {
            queue = originalQueue
            index = originalQueue.firstIndex { $0.id == cur.id } ?? 0
        }
    }

    func cycleRepeat() {
        let all = RepeatMode.allCases
        repeatMode = all[(all.firstIndex(of: repeatMode)! + 1) % all.count]
    }

    // MARK: 播放控制

    func togglePlayPause() {
        guard current != nil else { return }
        if player.currentItem == nil { load(autoplay: true); return }
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard player.currentItem != nil else { return }
        if let track = current {
            prepareOutput(for: track)
            // 暂停太久设备被还回去了，再占的时候 DoP 用不了（比如被别的 App 占了）：改成 PCM 接着放
            if case .dop(let rate) = stream, ExclusiveOutput.shared.dopProblem(rate: rate) != nil {
                reloadItem(autoplay: true)
                return
            }
        }
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        player.pause()
        ExclusiveOutput.shared.paused()
        isPlaying = false
        updateNowPlayingInfo()
        saveSession()
    }

    func next() {
        guard !queue.isEmpty else { return }
        index = (index + 1) % queue.count
        load(autoplay: true)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 { seek(to: 0); return }
        index = (index - 1 + queue.count) % queue.count
        load(autoplay: true)
    }

    func seek(to time: Double) {
        pendingRestoreTime = nil
        let t = max(0, min(time, duration > 0 ? duration : time))
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlayingInfo()
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    private func tick(_ time: CMTime) {
        if let target = pendingRestoreTime {
            // 恢复后还没准备好：进度先别被报成 0；准备好了还没到位置就再跳一次
            guard player.currentItem?.status == .readyToPlay else { return }
            pendingRestoreTime = nil
            if abs(time.seconds - target) > 1 { seek(to: target); return }
        }
        if time.seconds.isFinite { currentTime = time.seconds }
        if sessionDirty { saveQueue() }
        if isPlaying, abs(currentTime - lastSavedTime) >= 5 { savePosition() }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 {
            duration = d
        }
    }

    private func trackDidEnd() {
        if repeatMode == .one && !stopAfterCurrent {
            seek(to: 0)
            resume()
            return
        }
        let autoplay = !stopAfterCurrent
        if stopAfterCurrent { cancelSleepTimer() }

        if index + 1 < queue.count {
            index += 1
            load(autoplay: autoplay)
        } else if repeatMode == .all {
            index = 0
            load(autoplay: autoplay)
        } else {
            pause()
            seek(to: 0)
        }
    }

    private func load(autoplay: Bool) {
        guard let track = current else { return }
        player.replaceCurrentItem(with: makeItem(for: track))
        pendingRestoreTime = nil
        currentTime = 0
        lastSavedTime = 0
        duration = track.duration
        if autoplay {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
        loadExtras(for: track)
        updateNowPlayingInfo()
    }

    // MARK: 输出 / DSD

    /// 先选好输出设备、独占时切采样率，再做出要播放的 item。
    /// DSD 文件变成虚拟 WAV：独占 + 选了 DoP + 声卡支持时用 DoP，否则转成 PCM
    private func makeItem(for track: Track) -> AVPlayerItem {
        dsdLoader = nil
        guard track.isDSD else {
            stream = .file
            prepareOutput(for: track)
            return AVPlayerItem(url: track.url)
        }
        guard let file = DSDFile.read(url: track.url), !file.compressed else {
            stream = .file
            ExclusiveOutput.shared.show(notice: "这首 DFF 是 DST 压缩格式，暂时不能播放")
            return AVPlayerItem(url: track.url)
        }
        let output = ExclusiveOutput.shared
        var dopProblem: String?
        if output.enabled && output.dsdMode == .dop {
            let rate = Double(file.sampleRate / 16)
            if player.volume < 0.9999 {
                dopProblem = "音量不是 100%"
            } else {
                stream = .dop(rate: rate)
                prepareOutput(for: track)
                dopProblem = output.dopProblem(rate: rate)
                if dopProblem == nil, let decoder = DSDDecoder(url: track.url, file: file, mode: .dop) {
                    return makeDSDItem(decoder)
                }
            }
        }
        stream = .dsdPCM(rate: Double(DSDDecoder.pcmRate), dopProblem: dopProblem)
        prepareOutput(for: track)
        guard let decoder = DSDDecoder(url: track.url, file: file, mode: .pcm) else { return AVPlayerItem(url: track.url) }
        return makeDSDItem(decoder)
    }

    private func makeDSDItem(_ decoder: DSDDecoder) -> AVPlayerItem {
        let loader = DSDResourceLoader(decoder: decoder)
        dsdLoader = loader
        return AVPlayerItem(asset: loader.makeAsset())
    }

    /// 按现在交给 AVPlayer 的流选设备、切采样率
    private func prepareOutput(for track: Track) {
        let output = ExclusiveOutput.shared
        switch stream {
        case .file: output.prepare(player: player, sampleRate: track.sampleRate)
        case .dsdPCM(let rate, _): output.prepare(player: player, sampleRate: rate)
        case .dop(let rate): output.prepare(player: player, sampleRate: rate, dop: true)
        }
    }

    /// 输出设置变了：正在放 DSD 就按新设置重新载入（PCM / DoP 可能要换），接着原来的位置放
    private func outputSettingsChanged() -> Bool {
        guard let track = current, track.isDSD, player.currentItem != nil else { return false }
        reloadItem(autoplay: isPlaying)
        return true
    }

    private func reloadItem(autoplay: Bool) {
        guard let track = current else { return }
        let time = currentTime
        player.pause()
        player.replaceCurrentItem(with: makeItem(for: track))
        if time > 0 {
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if autoplay { player.play() }
        isPlaying = autoplay
        updateNowPlayingInfo()
    }

    // MARK: 歌词和封面

    private func loadExtras(for track: Track) {
        extrasTask?.cancel()
        lyrics = []
        lyricsSource = nil
        lyricOffset = Self.savedLyricOffset(for: track)
        resetAlignState()
        lyricsState = .loading
        nowPlayingArtwork = nil

        extrasTask = Task { [weak self] in
            let local = await LyricsProvider.local(for: track)
            guard let self, !Task.isCancelled, self.current?.id == track.id else { return }
            if let local { self.applyLyrics(local.text, source: local.source) }

            let art = await ArtworkProvider.shared.image(for: track, size: 400)
            guard !Task.isCancelled, self.current?.id == track.id else { return }
            self.nowPlayingArtwork = art
            self.updateNowPlayingInfo()

            // 用户删过的不再自动下载
            let wantLyrics = local == nil && !OnlineMedia.isLyricsBlocked(track)
            let wantCover = art == nil && !OnlineMedia.isCoverBlocked(track)
            if AppSettings.autoFetchOnline && (wantLyrics || wantCover) {
                await self.fetchOnline(for: track, lyrics: wantLyrics, cover: wantCover)
                if local == nil && !wantLyrics { self.lyricsState = .notFound }
            } else if local == nil {
                self.lyricsState = .notFound
            }
        }
    }

    // MARK: 联网搜索面板

    /// 打开「联网搜索」面板，列出各个来源的结果让用户自己选
    func openOnlineSearch(for track: Track? = nil) {
        searchTarget = track ?? current
    }

    /// 用面板里选的歌词，之后一直优先用它
    func applyManualLyrics(_ text: String, for track: Track) {
        OnlineMedia.saveManualLyrics(text, for: track)
        if current?.id == track.id { applyLyrics(text, source: .manual) }
    }

    func applyManualCover(_ data: Data, for track: Track) async {
        OnlineMedia.saveManualCover(data, for: track)
        await refreshCover(for: track)
    }

    /// 删除 App 下载/选择的歌词（不动音乐文件），然后按顺序重新找本地的
    func deleteOnlineLyrics(for track: Track) async {
        OnlineMedia.deleteOnlineLyrics(track)
        guard current?.id == track.id else { return }
        if let local = await LyricsProvider.local(for: track) {
            applyLyrics(local.text, source: local.source)
        } else {
            lyrics = []
            lyricsSource = nil
            lyricsState = .notFound
        }
    }

    func deleteOnlineCover(for track: Track) async {
        OnlineMedia.deleteOnlineCover(track)
        await refreshCover(for: track)
    }

    private func refreshCover(for track: Track) async {
        ArtworkProvider.shared.invalidate(track)
        guard current?.id == track.id else { return }
        nowPlayingArtwork = await ArtworkProvider.shared.image(for: track, size: 400)
        updateNowPlayingInfo()
    }

    private func fetchOnline(for track: Track, lyrics wantLyrics: Bool, cover wantCover: Bool) async {
        isFetchingOnline = true
        defer { isFetchingOnline = false }

        if wantLyrics, current?.id == track.id, lyrics.isEmpty { lyricsState = .loading }

        var lyricText: String?
        var coverData: Data?
        if wantLyrics { lyricText = await OnlineMedia.fetchLyrics(for: track) }
        if wantCover { coverData = await OnlineMedia.fetchCover(for: track) }
        if coverData != nil { ArtworkProvider.shared.invalidate(track) }

        guard current?.id == track.id else { return }
        if wantLyrics {
            if let lyricText {
                applyLyrics(lyricText, source: .online)
            } else if lyrics.isEmpty {
                lyricsState = .notFound
            }
        }
        if coverData != nil {
            nowPlayingArtwork = await ArtworkProvider.shared.image(for: track, size: 400)
            updateNowPlayingInfo()
        }
    }

    private func applyLyrics(_ text: String, source: LyricsSource) {
        let lines = LRCParser.parse(text)
        if lines != lyrics { resetAlignState() }
        lyrics = lines
        lyricsSource = lines.isEmpty ? nil : source
        lyricsState = lines.isEmpty ? .notFound : .loaded
    }

    // MARK: 睡眠定时

    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        let seconds = Double(minutes) * 60
        sleepDeadline = Date().addingTimeInterval(seconds)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pause()
                self?.sleepDeadline = nil
                self?.sleepTimer = nil
            }
        }
    }

    func setStopAfterCurrent() {
        cancelSleepTimer()
        stopAfterCurrent = true
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepDeadline = nil
        stopAfterCurrent = false
    }

    // MARK: 系统媒体键 / 控制中心

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.seek(to: time) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: lockScreenSubtitle(for: track),
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let image = nowPlayingArtwork {
            // 同一张封面只生成一次，换句更新歌词时不用重新传图
            if image !== artworkSource {
                artworkSource = image
                artworkItem = Self.makeArtwork(image)
            }
            info[MPMediaItemPropertyArtwork] = artworkItem
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    @ObservationIgnored private var artworkSource: NSImage?
    @ObservationIgnored private var artworkItem: MPMediaItemArtwork?

    /// 系统「正在播放」第二行：有带时间轴的歌词就显示当前这句，没有（或者间奏空行）就显示歌手
    private func lockScreenSubtitle(for track: Track) -> String {
        guard AppSettings.lockScreenLyrics, hasSyncedLyrics,
              let i = lockLyricIndex, lyrics.indices.contains(i) else { return track.artist }
        let line = lyrics[i].text.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? track.artist : line
    }

    /// 设置里开关「在系统『正在播放』里显示歌词」后马上刷新
    func refreshLockScreen() { updateNowPlayingInfo() }

    /// 系统会在后台线程来取封面，所以这个闭包不能绑在主线程上
    nonisolated private static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
