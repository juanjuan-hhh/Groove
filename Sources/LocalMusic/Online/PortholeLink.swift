import Foundation
import Observation

/// 把正在播放的歌词同步到 Porthole 桌面小屏（经本机的 Porthole bridge：http://127.0.0.1:8080）。
/// 换歌 / 歌词载入后把歌名、歌手和整首带时间轴的歌词发一次，小屏收到后自己按时间换句；
/// 之后只在暂停、继续、拖进度、调整歌词时间时发一个小的进度同步（外加每 20 秒一次心跳）。
/// bridge 没开时静默跳过，每 10 秒才再试一次，不影响播放。
/// 没装 Porthole（找不到 bridge）时设置里的开关变灰、不发任何东西。
@MainActor
@Observable
final class PortholeLink {
    static let shared = PortholeLink()

    /// 设置里的开关「在 Porthole 上显示歌词」
    static let enabledKey = "portholeLyrics"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// 这台 Mac 上装了 Porthole：装过 Porthole bridge（它的程序文件夹或开机自启项在）。每 10 秒重新看一次
    private(set) var installed = PortholeLink.detectInstalled()
    @ObservationIgnored private var checkedAt = Date()

    private static func detectInstalled() -> Bool {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return [library.appendingPathComponent("Application Support/Porthole Bridge"),
                library.appendingPathComponent("LaunchAgents/com.porthole.bridge.plist")]
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static let base = URL(string: "http://127.0.0.1:8080")!
    private static let heartbeat: TimeInterval = 20
    private static let retryAfter: TimeInterval = 10
    /// 实际进度和按上次同步推算的差这么多秒，就当作拖了进度
    private static let seekTolerance = 0.8

    @ObservationIgnored private weak var player: PlayerController?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var sentKey: Int?           // 已发给 bridge 的那首歌 + 那份歌词；nil = 小屏上没有
    @ObservationIgnored private var sentPlaying = false
    @ObservationIgnored private var sentPos = 0.0           // 上次同步的进度（秒，已含歌词时间调整）
    @ObservationIgnored private var sentAt = Date.distantPast
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var retryAt = Date.distantPast

    @ObservationIgnored private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        return URLSession(configuration: config)
    }()

    func start(player: PlayerController) {
        self.player = player
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        if Date().timeIntervalSince(checkedAt) >= Self.retryAfter {
            checkedAt = Date()
            let found = Self.detectInstalled()
            if found != installed { installed = found }
        }
        guard !busy, Date() >= retryAt, let player else { return }
        guard Self.enabled, installed, let track = player.current else {
            if sentKey != nil { send("/nowplaying/stop", [:]) { $0.sentKey = nil } }
            return
        }
        var hasher = Hasher()
        hasher.combine(track.path)
        hasher.combine(player.lyrics)
        let key = hasher.finalize()
        // 和歌词页亮起那一句用的是同一个时间（见 PlayerController.refreshLyricIndex）
        let pos = player.currentTime + 0.15 + player.lyricOffset
        let playing = player.isPlaying
        if key != sentKey {
            let lines: [[Any]] = player.hasSyncedLyrics
                ? player.lyrics.compactMap { line in line.time.map { [Int(($0 * 1000).rounded()), line.text] } }
                : []
            send("/nowplaying", ["title": track.title, "artist": track.artist, "dur": Int(player.duration * 1000),
                                 "lines": lines, "playing": playing, "pos": Int(pos * 1000)]) {
                $0.sentKey = key
                $0.synced(playing, pos)
            }
            return
        }
        let expected = sentPlaying ? sentPos + Date().timeIntervalSince(sentAt) : sentPos
        if playing != sentPlaying || abs(pos - expected) > Self.seekTolerance
            || Date().timeIntervalSince(sentAt) >= Self.heartbeat {
            send("/nowplaying/sync", ["playing": playing, "pos": Int(pos * 1000),
                                      "dur": Int(player.duration * 1000)]) { $0.synced(playing, pos) }
        }
    }

    private func synced(_ playing: Bool, _ pos: Double) {
        sentPlaying = playing
        sentPos = pos
        sentAt = Date()
    }

    /// 发成功才记下状态；失败（bridge 没开）就当小屏上什么都没有，下次连上时整首重发
    private func send(_ path: String, _ body: [String: Any], onSuccess: @escaping (PortholeLink) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        busy = true
        session.dataTask(with: request) { [weak self] _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                if ok {
                    onSuccess(self)
                } else {
                    self.sentKey = nil
                    self.retryAt = Date().addingTimeInterval(Self.retryAfter)
                }
            }
        }.resume()
    }
}
