import AppKit
import SwiftUI

// MARK: 底部迷你播放条

struct MiniPlayerBar: View {
    @Environment(PlayerController.self) private var player
    @State private var showQueue = false

    var body: some View {
        if let track = player.current {
            VStack(spacing: 0) {
                MiniProgressLine()
                HStack(spacing: 12) {
                    ArtworkView(track: track, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.ui(14, .bold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(track.artist).font(.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    IconButton(systemName: "backward.end.fill", size: 16, help: "上一首") { player.previous() }
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .offset(x: player.isPlaying ? 0 : 1)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Theme.accent))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(player.isPlaying ? "暂停" : "播放")
                    IconButton(systemName: "forward.end.fill", size: 16, help: "下一首") { player.next() }
                    IconButton(systemName: "list.bullet", size: 16, help: "播放队列") { showQueue.toggle() }
                        .popover(isPresented: $showQueue, arrowEdge: .top) {
                            QueueView().environment(player)
                        }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .foregroundStyle(Theme.text)
            }
            .background(Theme.card)
            .contentShape(Rectangle())
            .onTapGesture { player.showNowPlaying = true }
            .help("点击打开正在播放")
        }
    }
}

private struct MiniProgressLine: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        GeometryReader { geo in
            let fraction = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.track)
                Rectangle().fill(Theme.accent).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 2)
    }
}

// MARK: 播放队列

struct QueueView: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ChipText(text: "播放队列", color: Theme.accent, font: .ui(13, .bold), hPad: 12, vPad: 4)
                Text("\(player.queue.count) 首").font(.ui(13)).foregroundStyle(Theme.text2)
                Spacer()
            }
            .padding(12)
            ThemeDivider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { i, track in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(.ui(13, i == player.index ? .bold : .medium))
                                        .lineLimit(1)
                                        .foregroundStyle(i == player.index ? Theme.accent : Theme.text)
                                    Text(track.artist).font(.ui(11)).foregroundStyle(Theme.text2).lineLimit(1)
                                }
                                Spacer()
                                if i == player.index {
                                    Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Theme.accent)
                                } else {
                                    Button { player.removeFromQueue(at: i) } label: {
                                        Image(systemName: "xmark").font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.text3)
                                    .help("从队列中移除")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .onTapGesture { player.jump(to: i) }
                            .id(i)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(player.index, anchor: .center) }
            }
        }
        .frame(width: 320, height: 420)
        .background(Theme.card)
    }
}

// MARK: 正在播放

struct NowPlayingView: View {
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @State private var showQueue = false
    @State private var showQueueFromBottom = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background(geo.size)
                VStack(spacing: 0) {
                    header.padding(.top, 14).background(WindowDragArea())
                    if player.showLyrics {
                        LyricsView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if player.hasSyncedLyrics {
                            LyricOffsetControl().padding(.bottom, 14)
                        }
                    } else {
                        cover(in: geo.size)
                            .frame(maxHeight: .infinity)
                        functionRow.padding(.bottom, 14)
                    }
                    ProgressSection()
                    controls.padding(.vertical, 14)
                    upNext.padding(.bottom, 18)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .background {
            Button("") { player.showNowPlaying = false }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
    }

    private func background(_ size: CGSize) -> some View {
        let side = max(size.width, size.height)
        // 黑底为主，只透出一点模糊的封面颜色
        return ZStack {
            Theme.bg
            ArtworkView(track: player.current, size: 320, cornerRadius: 0)
                .scaleEffect(side / 320 * 1.4)
                .blur(radius: 70)
                .opacity(0.4)
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            IconButton(systemName: "chevron.down", size: 20, help: "收起（Esc）") { player.showNowPlaying = false }
            Spacer()
            VStack(spacing: 4) {
                Text(player.current?.title ?? "")
                    .font(.ui(16, .bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let track = player.current { QualityBadge(quality: track.quality) }
                    Text(player.current?.artist ?? "")
                        .font(.ui(13))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                }
            }
            Spacer()
            IconButton(systemName: player.showLyrics ? "photo" : "quote.bubble", size: 17,
                       help: player.showLyrics ? "显示封面" : "显示歌词") {
                player.showLyrics.toggle()
            }
            Menu {
                if let source = player.lyricsSource {
                    Text("歌词来源：\(source.rawValue)")
                    Divider()
                }
                Button("联网搜索封面和歌词…") { player.openOnlineSearch() }
                if let track = player.current {
                    Button("删除歌词（只删 App 下载的）") { Task { await player.deleteOnlineLyrics(for: track) } }
                        .disabled(player.lyricsSource != .online && player.lyricsSource != .manual)
                    Button("删除封面（只删 App 下载的）") { Task { await player.deleteOnlineCover(for: track) } }
                        .disabled(!OnlineMedia.hasOnlineCover(track))
                }
                Divider()
                LyricOffsetMenuItems()
                if let track = player.current {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 17))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func cover(in size: CGSize) -> some View {
        let side = max(150, min(340, size.height - 420, size.width - 96))
        return VStack(spacing: 30) {
            ArtworkView(track: player.current, size: side, circle: true)
                .overlay { ProgressRing() }
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                .onTapGesture { player.showLyrics = true }
            CurrentLyricLine()
                .onTapGesture { player.showLyrics = true }
        }
    }

    private var functionRow: some View {
        let track = player.current
        let isFavorite = track.map { library.isFavorite($0) } ?? false
        return HStack {
            Spacer()
            IconButton(systemName: isFavorite ? "heart.fill" : "heart", size: 18, help: isFavorite ? "取消收藏" : "收藏") {
                if let track { library.toggleFavorite(track) }
            }
            .foregroundStyle(isFavorite ? Theme.accent : Theme.text)
            Spacer()
            IconButton(systemName: "shuffle", size: 18, active: player.shuffle, help: player.shuffle ? "随机播放：开" : "随机播放：关") {
                player.toggleShuffle()
            }
            .foregroundStyle(player.shuffle ? Theme.accent : Theme.text)
            Spacer()
            IconButton(systemName: player.repeatMode.symbol, size: 18, help: player.repeatMode.label) {
                player.cycleRepeat()
            }
            .foregroundStyle(player.repeatMode == .off ? Theme.text : Theme.accent)
            Spacer()
            IconButton(systemName: "list.bullet", size: 18, help: "播放队列") { showQueue.toggle() }
                .popover(isPresented: $showQueue) { QueueView().environment(player) }
            Spacer()
            SleepTimerMenu(size: 18)
            Spacer()
        }
        .opacity(0.9)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Spacer()
            IconButton(systemName: "backward.fill", size: 22, help: "快退 10 秒") { player.skip(by: -10) }
            Spacer()
            IconButton(systemName: "backward.end.fill", size: 24, help: "上一首") { player.previous() }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .offset(x: player.isPlaying ? 0 : 2)
                    .frame(width: 68, height: 68)
                    .background(Circle().fill(Theme.accent))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 14)
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "暂停（空格）" : "播放（空格）")
            Spacer()
            IconButton(systemName: "forward.end.fill", size: 24, help: "下一首") { player.next() }
            Spacer()
            IconButton(systemName: "forward.fill", size: 22, help: "快进 10 秒") { player.skip(by: 10) }
            Spacer()
        }
    }

    private var upNext: some View {
        Button { showQueueFromBottom.toggle() } label: {
            Text("下一首：\(player.upNext?.title ?? "无")")
                .font(.ui(13, .semibold))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Capsule().fill(Theme.surface))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showQueueFromBottom) { QueueView().environment(player) }
    }
}

/// 圆形封面外的一圈进度环（Porthole 表盘的圆环）
private struct ProgressRing: View {
    @Environment(PlayerController.self) private var player
    private let width: CGFloat = 6

    var body: some View {
        let fraction = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
        ZStack {
            Circle().stroke(Theme.track, lineWidth: width)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(-14)
        .allowsHitTesting(false)
    }
}

/// 歌词时间调整：[延后 0.5s] 当前调整量 [提前 0.5s]，点中间复位
struct LyricOffsetControl: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        let step = PlayerController.lyricOffsetStep
        HStack(spacing: 4) {
            stepButton("minus", "延后", help: "歌词延后 0.5 秒（歌词比歌快时用）") { player.adjustLyricOffset(by: -step) }
            Button { player.resetLyricOffset() } label: {
                Text(player.lyricOffsetLabel)
                    .font(.ui(13, .bold).monospacedDigit())
                    .foregroundStyle(player.lyricOffset == 0 ? Theme.text2 : Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(player.lyricOffset == 0 ? .clear : Theme.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(player.lyricOffset == 0)
            .help("点击复位")
            stepButton("plus", "提前", help: "歌词提前 0.5 秒（歌词比歌慢时用）") { player.adjustLyricOffset(by: step) }
        }
        .padding(4)
        .background(Capsule().fill(Theme.card))
        .animation(.easeInOut(duration: 0.15), value: player.lyricOffset)
    }

    private func stepButton(_ symbol: String, _ text: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .heavy))
                Text("\(text) 0.5s").font(.ui(12, .bold))
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.surface))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 菜单里的歌词时间调整（正在播放页的 ⋯ 菜单和顶部「播放」菜单共用）
struct LyricOffsetMenuItems: View {
    @Environment(PlayerController.self) private var player
    var showShortcuts = false

    var body: some View {
        let step = PlayerController.lyricOffsetStep
        Button("歌词提前 0.5 秒（歌词慢了）") { player.adjustLyricOffset(by: step) }
            .disabled(!player.hasSyncedLyrics)
            .keyboardShortcut(showShortcuts ? KeyboardShortcut("]", modifiers: [.command, .option]) : nil)
        Button("歌词延后 0.5 秒（歌词快了）") { player.adjustLyricOffset(by: -step) }
            .disabled(!player.hasSyncedLyrics)
            .keyboardShortcut(showShortcuts ? KeyboardShortcut("[", modifiers: [.command, .option]) : nil)
        Button("歌词时间复位（\(player.lyricOffsetLabel)）") { player.resetLyricOffset() }
            .disabled(player.lyricOffset == 0)
    }
}

/// 封面下方的当前一句歌词
private struct CurrentLyricLine: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        Text(text)
            .font(.ui(17, .semibold))
            .foregroundStyle(Theme.text2)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(height: 48)
            .animation(.easeInOut(duration: 0.2), value: text)
    }

    private var text: String {
        switch player.lyricsState {
        case .loading: return "正在加载歌词…"
        case .loaded:
            if let i = player.currentLyricIndex { return player.lyrics[i].text }
            return player.lyrics.first?.time == nil ? "" : (player.current?.title ?? "")
        case .notFound, .idle: return "暂无歌词"
        }
    }
}

/// 进度条 + 时间
private struct ProgressSection: View {
    @Environment(PlayerController.self) private var player
    @State private var dragTime: Double?
    @State private var hovering = false

    var body: some View {
        let duration = max(player.duration, 1)
        let time = dragTime ?? player.currentTime
        VStack(spacing: 8) {
            // Porthole 的粗胶囊进度条，播放时有光带滑过；点击或拖动跳转
            GeometryReader { geo in
                CapsuleBar(value: time / duration, height: hovering || dragTime != nil ? 10 : 8,
                           shimmer: player.isPlaying && dragTime == nil)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragTime = min(1, max(0, value.location.x / geo.size.width)) * duration
                            }
                            .onEnded { _ in
                                if let t = dragTime { player.seek(to: t) }
                                dragTime = nil
                            }
                    )
            }
            .frame(height: 18)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            HStack {
                Text(formatTime(time))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.ui(12, .semibold).monospacedDigit())
            .foregroundStyle(Theme.text2)
        }
    }
}

// MARK: 歌词页

struct LyricsView: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        switch player.lyricsState {
        case .loading, .idle:
            ProgressView().controlSize(.small).tint(Theme.text2)
        case .notFound:
            VStack(spacing: 14) {
                Text("暂无歌词").font(.ui(18, .semibold)).foregroundStyle(Theme.text2)
                Button { player.openOnlineSearch() } label: {
                    ChipText(text: player.isFetchingOnline ? "正在搜索…" : "联网搜索歌词", color: Theme.accent,
                             font: .ui(14, .bold), hPad: 18, vPad: 8)
                }
                .buttonStyle(.plain)
                .disabled(player.isFetchingOnline)
            }
        case .loaded:
            if player.lyrics.first?.time == nil {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        ForEach(player.lyrics) { line in
                            Text(line.text).font(.ui(17, .medium)).foregroundStyle(Theme.text)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            } else {
                SyncedLyrics()
            }
        }
    }
}

private struct SyncedLyrics: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        let lines = player.lyrics
        let current = player.currentLyricIndex
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    Color.clear.frame(height: 160)
                    ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                        Text(line.text)
                            .font(.ui(i == current ? 26 : 19, i == current ? .heavy : .semibold))
                            .foregroundStyle(i == current ? Theme.text : Theme.text3)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { if let t = line.time { player.seek(toLyric: t) } }
                            .id(line.id)
                    }
                    Color.clear.frame(height: 160)
                }
                .padding(.horizontal, 24)
                .animation(.easeInOut(duration: 0.25), value: current)
            }
            .onAppear {
                if let current { proxy.scrollTo(lines[current].id, anchor: .center) }
            }
            .onChange(of: current) { _, newValue in
                guard let newValue, lines.indices.contains(newValue) else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(lines[newValue].id, anchor: .center)
                }
            }
        }
    }
}
