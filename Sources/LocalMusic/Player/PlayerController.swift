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

enum LyricsState: Equatable {
    case idle, loading, loaded, notFound
}

/// 播放器：播放队列、随机/循环、进度、睡眠定时、当前歌曲的歌词和封面
@MainActor
@Observable
final class PlayerController {
    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var shuffle = false
    private(set) var repeatMode: RepeatMode = .all
    var showNowPlaying = false
    var showLyrics = false

    private(set) var lyrics: [LyricLine] = []
    private(set) var lyricsState: LyricsState = .idle
    private(set) var lyricsSource: LyricsSource?
    /// 歌词时间调整（秒）：正数表示歌词提前出现，负数表示延后。每首歌单独保存
    private(set) var lyricOffset: Double = 0
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

    var upNext: Track? {
        guard !queue.isEmpty else { return nil }
        if repeatMode == .one { return current }
        if index + 1 < queue.count { return queue[index + 1] }
        return repeatMode == .all ? queue.first : nil
    }

    var sleepActive: Bool { sleepDeadline != nil || stopAfterCurrent }

    var currentLyricIndex: Int? { LRCParser.index(in: lyrics, at: currentTime + 0.15 + lyricOffset) }

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

    private func setLyricOffset(_ value: Double) {
        guard let track = current else { return }
        let rounded = (value * 2).rounded() / 2   // 保持 0.5 的整数倍，避免浮点误差累积
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
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
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
        let t = max(0, min(time, duration > 0 ? duration : time))
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlayingInfo()
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    private func tick(_ time: CMTime) {
        if time.seconds.isFinite { currentTime = time.seconds }
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
        player.replaceCurrentItem(with: AVPlayerItem(url: track.url))
        currentTime = 0
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

    // MARK: 歌词和封面

    private func loadExtras(for track: Track) {
        extrasTask?.cancel()
        lyrics = []
        lyricsSource = nil
        lyricOffset = Self.savedLyricOffset(for: track)
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
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let image = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}
