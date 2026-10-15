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
                    ArtworkView(track: track, size: 44, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text(track.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    IconButton(systemName: "backward.end.fill", size: 16, help: "上一首") { player.previous() }
                    IconButton(systemName: player.isPlaying ? "pause.fill" : "play.fill", size: 22,
                               help: player.isPlaying ? "暂停" : "播放") { player.togglePlayPause() }
                    IconButton(systemName: "forward.end.fill", size: 16, help: "下一首") { player.next() }
                    IconButton(systemName: "list.bullet", size: 16, help: "播放队列") { showQueue.toggle() }
                        .popover(isPresented: $showQueue, arrowEdge: .top) {
                            QueueView().environment(player)
                        }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .background(.bar)
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
                Rectangle().fill(Color.primary.opacity(0.08))
                Rectangle().fill(Color.accentColor).frame(width: geo.size.width * fraction)
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
                Text("播放队列").font(.headline)
                Text("\(player.queue.count) 首").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { i, track in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .lineLimit(1)
                                        .foregroundStyle(i == player.index ? Color.accentColor : Color.primary)
                                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if i == player.index {
                                    Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Color.accentColor)
                                } else {
                                    Button { player.removeFromQueue(at: i) } label: {
                                        Image(systemName: "xmark").font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
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
                    header.padding(.top, 14)
                    if player.showLyrics {
                        LyricsView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .foregroundStyle(.white)
        .background(Color(white: 0.12))
        .background {
            Button("") { player.showNowPlaying = false }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
    }

    private func background(_ size: CGSize) -> some View {
        let side = max(size.width, size.height)
        return ZStack {
            Color(white: 0.18)
            ArtworkView(track: player.current, size: 320, cornerRadius: 0)
                .scaleEffect(side / 320 * 1.4)
                .blur(radius: 60)
                .opacity(0.85)
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
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
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let track = player.current { QualityBadge(quality: track.quality) }
                    Text(player.current?.artist ?? "")
                        .font(.system(size: 13))
                        .opacity(0.85)
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
                Button(player.isFetchingOnline ? "正在联网搜索…" : "联网搜索封面和歌词") { player.searchOnline() }
                    .disabled(player.isFetchingOnline)
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
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
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
            .foregroundStyle(isFavorite ? Color.pink : Color.white)
            Spacer()
            IconButton(systemName: "shuffle", size: 18, active: player.shuffle, help: player.shuffle ? "随机播放：开" : "随机播放：关") {
                player.toggleShuffle()
            }
            Spacer()
            IconButton(systemName: player.repeatMode.symbol, size: 18, help: player.repeatMode.label) {
                player.cycleRepeat()
            }
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
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                    .offset(x: player.isPlaying ? 0 : 2)
                    .frame(width: 68, height: 68)
                    .background(Circle().fill(.white))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
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
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showQueueFromBottom) { QueueView().environment(player) }
    }
}

/// 封面下方的当前一句歌词
private struct CurrentLyricLine: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
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
    @State private var editing = false

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { dragTime ?? player.currentTime },
                    set: { value in
                        if editing { dragTime = value } else { player.seek(to: value) }
                    }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { isEditing in
                    editing = isEditing
                    if !isEditing, let t = dragTime {
                        player.seek(to: t)
                        dragTime = nil
                    }
                }
            )
            .tint(.white)
            .controlSize(.small)
            HStack {
                Text(formatTime(dragTime ?? player.currentTime))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.system(size: 12).monospacedDigit())
            .opacity(0.75)
        }
    }
}

// MARK: 歌词页

struct LyricsView: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        switch player.lyricsState {
        case .loading, .idle:
            ProgressView().controlSize(.small).tint(.white)
        case .notFound:
            VStack(spacing: 14) {
                Text("暂无歌词").font(.system(size: 18, weight: .medium)).opacity(0.8)
                Button(player.isFetchingOnline ? "正在搜索…" : "联网搜索歌词") { player.searchOnline() }
                    .disabled(player.isFetchingOnline)
            }
        case .loaded:
            if player.lyrics.first?.time == nil {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        ForEach(player.lyrics) { line in
                            Text(line.text).font(.system(size: 17)).opacity(0.85)
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
                            .font(.system(size: i == current ? 26 : 19, weight: i == current ? .bold : .medium))
                            .foregroundStyle(.white.opacity(i == current ? 1 : 0.5))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { if let t = line.time { player.seek(to: t) } }
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
