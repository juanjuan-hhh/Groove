import AppKit
import SwiftUI

// MARK: 底部迷你播放条

/// 一直显示在底部；还没放歌时显示「未在播放」，点播放键从整个歌曲库开始放
struct MiniPlayerBar: View {
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @State private var showQueue = false
    /// 左边（封面 + 歌名）和右边（播放按钮）各占多宽，用来算中间歌词能用多宽
    @State private var leftWidth: CGFloat = 0
    @State private var rightWidth: CGFloat = 0

    var body: some View {
        let track = player.current
        VStack(spacing: 0) {
            MiniProgressLine()
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    ArtworkView(track: track, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track?.title ?? "未在播放").font(.ui(14, .bold))
                            .foregroundStyle(track == nil ? Theme.text2 : Theme.text).lineLimit(1)
                        Text(track?.artist ?? (library.tracks.isEmpty ? "先添加音乐文件夹" : "双击一首歌，或点播放键开始"))
                            .font(.ui(12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: 240, alignment: .leading)
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { leftWidth = $0 }
                Spacer(minLength: 12)
                controls
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { rightWidth = $0 }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .foregroundStyle(Theme.text)
            // 歌词放在整条的正中间；左右各让出较宽一边的宽度，保证不压到歌名和按钮
            .overlay {
                GeometryReader { geo in
                    let side = max(leftWidth, rightWidth) + 20 + 16
                    MiniLyricLine()
                        .frame(width: max(0, geo.size.width - side * 2))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // 用了自定义背景图时底栏半透明，和背景连成一片（不再是一整块实心的底色）
        .background(AppBackground.shared.image == nil ? Theme.card : Theme.card.opacity(0.3))
        .contentShape(Rectangle())
        .onTapGesture { if track != nil { player.showNowPlaying = true } }
        .help(track == nil ? "" : "点击打开正在播放")
    }

    /// 还没放歌时按播放：按当前排序从整个歌曲库开始放（开了随机就随机）
    private func playOrStart() {
        if player.current != nil {
            player.togglePlayPause()
            return
        }
        let all = library.sorted(library.tracks, by: library.sort, ascending: library.ascending)
        guard !all.isEmpty else { return }
        if player.shuffle { player.playShuffled(all) } else { player.play(all) }
    }

    private var controls: some View {
        let idle = player.current == nil
        return HStack(spacing: 12) {
            IconButton(systemName: "backward.end.fill", size: 16, help: "上一首") { player.previous() }
                .disabled(idle).opacity(idle ? 0.35 : 1)
            Button { playOrStart() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .offset(x: player.isPlaying ? 0 : 1)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.accent))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(idle && library.tracks.isEmpty)
            .help(idle ? "从歌曲库开始播放" : (player.isPlaying ? "暂停" : "播放"))
            IconButton(systemName: "forward.end.fill", size: 16, help: "下一首") { player.next() }
                .disabled(idle).opacity(idle ? 0.35 : 1)
            IconButton(systemName: "list.bullet", size: 16, help: "播放队列") { showQueue.toggle() }
                .popover(isPresented: $showQueue, arrowEdge: .top) {
                    QueueView().environment(player)
                }
                .disabled(idle).opacity(idle ? 0.35 : 1)
        }
    }
}

/// 底部播放条中间的当前一句歌词（只有带时间轴的歌词才显示），点它直接打开歌词页
private struct MiniLyricLine: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        let line = currentLine
        ZStack {
            if let line {
                Text(line)
                    .font(.ui(14, .semibold))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(line)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: 20)
        .clipped()
        .animation(.easeInOut(duration: 0.35), value: line)
        .contentShape(Rectangle())
        .allowsHitTesting(line != nil)   // 没歌词时点这里和点播放条其他地方一样
        .onTapGesture {
            player.showLyrics = true
            player.showNowPlaying = true
        }
        .help(line == nil ? "" : "点击打开歌词")
    }

    private var currentLine: String? {
        guard player.hasSyncedLyrics, let i = player.currentLyricIndex, player.lyrics.indices.contains(i) else { return nil }
        let text = player.lyrics[i].text
        return text.isBlank ? nil : text
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
                            QueueRow { HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(.ui(13, i == player.index ? .bold : .medium))
                                        .lineLimit(1)
                                        .foregroundStyle(i == player.index ? Theme.accent : Theme.text)
                                    Text(track.artist).font(.ui(11)).foregroundStyle(Theme.text2).lineLimit(1)
                                }
                                Spacer()
                                if i == player.index {
                                    PlayingBars(isPlaying: player.isPlaying)
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
                            }
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

/// 队列里的一行：鼠标放上去时浅浅地高亮（半选中）
private struct QueueRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .fill(Theme.surface.opacity(hovering ? 0.8 : 0))
                    .padding(.horizontal, 6)
            }
            .onHover { hovering = $0 }
    }
}

// MARK: 正在播放

struct NowPlayingView: View {
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @State private var showQueue = false
    @State private var showQueueFromBottom = false
    /// 和设置菜单里的「播放时旋转封面」是同一个开关
    @AppStorage(SpinningArtwork.enabledKey) private var spinCover = true

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    header.padding(.top, 14).background(WindowDragArea())
                    // 封面 ↔ 歌词切换：封面缩小淡出、歌词从下面浮上来淡入（反过来也一样）
                    ZStack {
                        if player.showLyrics {
                            VStack(spacing: 0) {
                                LyricsView()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .mask(LyricsFadeMask())
                                    .padding(.top, 22)
                                if player.adjustingLyrics && player.hasSyncedLyrics {
                                    LyricOffsetBar()
                                        .padding(.bottom, 14)
                                        .transition(.opacity)
                                }
                            }
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 30)),
                                                    removal: .opacity.combined(with: .offset(y: 30))))
                        } else {
                            VStack(spacing: 0) {
                                // 封面按剩下的空间算大小，窗口矮时缩小，不会往上压到标题和歌手
                                GeometryReader { area in
                                    cover(in: area.size)
                                        .frame(width: area.size.width, height: area.size.height)
                                }
                                .frame(maxHeight: .infinity)
                                .padding(.top, 20)   // 和上面的歌名、歌手隔开一点
                                functionRow.padding(.bottom, 14)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.88)))
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .animation(.spring(response: 0.42, dampingFraction: 0.9), value: player.showLyrics)
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
        // 右上角：打开 / 关闭悬浮球（和主窗口顶栏最右边那个一样）
        .overlay(alignment: .topTrailing) {
            BallToggleButton(size: 17)
                .padding(.top, 18)
            .padding(.trailing, 20)
        }
        // 模糊的封面色一直铺到窗口最上面（标题栏下面）
        .background {
            GeometryReader { geo in background(geo.size) }
                .ignoresSafeArea()
                .padding(.top, -ContentView.titleBarHeight)
        }
        // 关掉正在播放页时，歌词调整也一起关掉，下次打开是干净的
        .onDisappear { player.adjustingLyrics = false }
        .background {
            Button("") { player.showNowPlaying = false }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
    }

    private func background(_ size: CGSize) -> some View {
        let side = max(size.width, size.height)
        // 底色为主（深色黑、浅色白），只透出一点模糊的封面颜色
        return ZStack {
            Theme.bg
            ArtworkView(track: player.current, size: 320, cornerRadius: 0)
                .scaleEffect(side / 320 * 1.4)
                .blur(radius: 70)
                .opacity(0.4)
            LinearGradient(colors: [Theme.bg.opacity(0.35), Theme.bg.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// 44100 → "44.1kHz"，96000 → "96kHz"
    static func khz(_ rate: Double) -> String {
        let k = rate / 1000
        return k == k.rounded() ? "\(Int(k))kHz" : String(format: "%.1fkHz", k)
    }

    private var header: some View {
        // 歌名和歌手放在整行正中间（左右按钮宽度不一样，放在 HStack 里会偏左）
        ZStack {
            VStack(spacing: 4) {
                Text(player.current?.title ?? "")
                    .font(.ui(16, .bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let track = player.current { QualityBadge(track: track) }
                    // 独占输出时显示设备实际的采样率，确认没有被重采样
                    if let rate = ExclusiveOutput.shared.outputRate {
                        Button { SignalPathWindow.shared.show(player: player) } label: {
                            ChipText(text: "输出 " + Self.khz(rate), color: Theme.surface, foreground: Theme.text,
                                     font: .ui(10, .bold), hPad: 7, vPad: 2)
                        }
                        .buttonStyle(.plain)
                        .help("独占输出中，声卡现在的采样率。点击查看音频链路")
                    }
                    Text(player.current?.artist ?? "")
                        .font(.ui(13))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 90)
            HStack(alignment: .center, spacing: 8) {
                IconButton(systemName: "chevron.down", size: 20, help: "收起（Esc）") { player.showNowPlaying = false }
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
                        Button("自定义封面…") { player.chooseCustomCover(for: track) }
                        Button("导入本地歌词…") { player.importLocalLyrics(for: track) }
                        Button("删除歌词（仅删除 App 下载数据）") { Task { await player.deleteOnlineLyrics(for: track) } }
                            .disabled(player.lyricsSource != .online && player.lyricsSource != .manual)
                        Button("删除封面（仅删除 App 下载数据）") { Task { await player.deleteOnlineCover(for: track) } }
                            .disabled(!OnlineMedia.hasOnlineCover(track))
                    }
                    Divider()
                    // 开启：切到歌词页，下方出现「延后 / 提前」按钮，点哪句歌词对齐哪句；关闭：收起（每次调整当时就已保存）
                    Button(player.adjustingLyrics ? "关闭歌词调整" : "开启歌词调整（\(player.lyricOffsetLabel)）") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if player.adjustingLyrics {
                                player.adjustingLyrics = false
                            } else {
                                player.adjustingLyrics = true
                                player.showLyrics = true
                            }
                        }
                    }
                    .disabled(!player.hasSyncedLyrics)
                    Toggle("播放时旋转封面", isOn: $spinCover)
                    if let track = player.current {
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 17))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .iconBacking(31)
            }
        }
    }

    private func cover(in size: CGSize) -> some View {
        // 封面下面还有：进度环外扩 14×2、间距 30、当前歌词 48、间距 18、格式标签 26，上下再各留 12
        let side = max(60, min(340, size.height - 200, size.width - 96))
        // 多出来的空间：封面上下各分一点，当前歌词和格式标签放在最下面，靠近下面的按钮和进度条
        return VStack(spacing: 18) {
            Spacer(minLength: 0)
            SpinningArtwork(track: player.current, size: side)
                .overlay { ProgressRing() }
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                .onTapGesture { player.showLyrics = true }
            Spacer(minLength: 12)
            CurrentLyricLine()
                .onTapGesture { player.showLyrics = true }
                .offset(y: -10)   // 只把歌词往上挪一点，格式标签不动
            // 格式信息：FLAC · 16bit · 44.1kHz
            // 点它打开「音频链路」
            if let track = player.current {
                Button { SignalPathWindow.shared.show(player: player) } label: {
                    ChipText(text: track.formatDescription, color: Theme.surface, foreground: Theme.text2,
                             font: .ui(12, .bold).monospacedDigit(), hPad: 12, vPad: 5)
                }
                .buttonStyle(.plain)
                .help("查看音频链路")
                .padding(.top, -20)
            }
        }
        .padding(.bottom, 16)   // 和下面一排按钮隔开
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
            IconButton(systemName: "gobackward.10", size: 22, help: "快退 10 秒") { player.skip(by: -10) }
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
            IconButton(systemName: "goforward.10", size: 22, help: "快进 10 秒") { player.skip(by: 10) }
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

/// 歌词区上下边缘渐隐：滚到顶部 / 底部的歌词慢慢淡出，而不是被一刀切掉
private struct LyricsFadeMask: View {
    var top: CGFloat = 70
    var bottom: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: top)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: bottom)
        }
    }
}

/// 歌词时间调整（正在播放页 ⋯ 菜单里的「歌词调整」和顶部「播放」菜单共用）
struct LyricOffsetMenuItems: View {
    @Environment(PlayerController.self) private var player
    var showShortcuts = false

    var body: some View {
        let step = PlayerController.lyricOffsetStep
        Button("歌词延后 0.25 秒（歌词快了）") { player.adjustLyricOffset(by: -step) }
            .disabled(!player.hasSyncedLyrics)
            .keyboardShortcut(showShortcuts ? KeyboardShortcut("[", modifiers: [.command, .option]) : nil)
        Button("歌词提前 0.25 秒（歌词慢了）") { player.adjustLyricOffset(by: step) }
            .disabled(!player.hasSyncedLyrics)
            .keyboardShortcut(showShortcuts ? KeyboardShortcut("]", modifiers: [.command, .option]) : nil)
        Button("歌词时间复位（\(player.lyricOffsetLabel)）") { player.resetLyricOffset() }
            .disabled(player.lyricOffset == 0)
    }
}

/// 封面下方的当前一句歌词
private struct CurrentLyricLine: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        // 换句时新的一句从下面滑上来、旧的往上滑走，而不是原地闪一下
        ZStack {
            Text(text)
                .font(.ui(17, .semibold))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .id(text)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
        }
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(.easeInOut(duration: 0.35), value: text)
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
    @State private var hovering = false

    /// 拖动中的时间放在 player 里，歌词页、封面下那句歌词会跟着拖动的位置走
    private var dragTime: Double? {
        get { player.scrubTime }
        nonmutating set { player.scrubTime = newValue }
    }

    var body: some View {
        let duration = max(player.duration, 1)
        let time = dragTime ?? player.currentTime
        VStack(spacing: 8) {
            // Porthole 的粗胶囊进度条，播放时有光带滑过；点击或拖动跳转
            GeometryReader { geo in
                let fraction = min(1, max(0, time / duration))
                CapsuleBar(value: fraction, height: hovering || dragTime != nil ? 10 : 8,
                           shimmer: player.isPlaying && dragTime == nil)
                    .frame(maxHeight: .infinity)
                    // 拖动时进度条头上冒出一个圆头小点
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(Theme.cream)
                            .overlay(Circle().stroke(Theme.accent, lineWidth: 3))
                            .frame(width: 18, height: 18)
                            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                            .scaleEffect(dragTime != nil ? 1 : 0.01)
                            .opacity(dragTime != nil ? 1 : 0)
                            .offset(x: geo.size.width * fraction - 9)
                            .allowsHitTesting(false)
                            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragTime != nil)
                    }
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
    /// 正在用滚轮 / 触控板翻歌词：这时不自动滚回当前这句，免得和手抢
    @State private var userBrowsing = false
    /// 停下后等一会儿再回到当前这句
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        let lines = player.lyrics
        let current = player.currentLyricIndex
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    Color.clear.frame(height: 160)
                    ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                        // 所有行用同一种字号：换字号 / 字重没法平滑过渡，只能闪一下换过去，行高还会跟着变。
                        // 当前这句用放大 + 变亮来突出，这两样都能平滑地动起来
                        Text(line.text)
                            .font(.ui(20, .heavy))
                            .foregroundStyle(i == current ? Theme.text : Theme.text3)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 10)
                            .scaleEffect(i == current ? 1.18 : 1, anchor: .center)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard let t = line.time else { return }
                                if player.adjustingLyrics {
                                    // 调整歌词时：听到哪句就点哪句，这一句马上对上现在的歌声
                                    player.alignLyric(at: t)
                                } else {
                                    player.seek(toLyric: t)
                                }
                            }
                            .id(line.id)
                    }
                    Color.clear.frame(height: 160)
                }
                .padding(.horizontal, 24)
                .animation(.easeInOut(duration: 0.4), value: current)   // 和滚动同样的节奏
            }
            .onAppear {
                if let current { proxy.scrollTo(lines[current].id, anchor: .center) }
            }
            .onChange(of: current) { _, newValue in
                // 拖动进度条时一定跟着走（就算刚刚翻过歌词）
                if player.scrubTime != nil {
                    resumeTask?.cancel()
                    userBrowsing = false
                }
                guard !userBrowsing, let newValue, lines.indices.contains(newValue) else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(lines[newValue].id, anchor: .center)
                }
            }
            .modifier(BrowseDetector { browsing in
                if browsing {
                    resumeTask?.cancel()
                    userBrowsing = true
                } else if userBrowsing {
                    // 停稳 3 秒后再慢慢回到正在唱的这句
                    resumeTask?.cancel()
                    resumeTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        userBrowsing = false
                        if let i = player.currentLyricIndex, player.lyrics.indices.contains(i) {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                proxy.scrollTo(player.lyrics[i].id, anchor: .center)
                            }
                        }
                    }
                }
            })
            .onDisappear { resumeTask?.cancel() }
        }
    }
}

/// 手动滚动歌词的检测（macOS 15 起有；更早的系统就不检测，歌词照常自动跟随）
private struct BrowseDetector: ViewModifier {
    let changed: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: changed(true)
                case .idle: changed(false)
                default: break   // .animating：我们自己 scrollTo 引起的滚动，不算手动
                }
            }
        } else {
            content
        }
    }
}

/// 歌词页底部的歌词时间调整：◀ 延后 ｜ 歌词提前 1.5s（点一下复位）｜ 提前 ▶ ，上面的小勾收起
struct LyricOffsetBar: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        let step = PlayerController.lyricOffsetStep
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                barButton("延后", icon: "backward.fill", leading: true) { player.adjustLyricOffset(by: -step) }
                    .help("歌词延后 0.25 秒（歌词快了）⌥⌘[")
                Button {
                    if player.lyricOffset != 0 { player.resetLyricOffset() }
                } label: {
                    Text(player.lyricOffsetLabel)
                        .font(.ui(13, .bold).monospacedDigit())
                        .foregroundStyle(player.lyricOffset == 0 ? Theme.text2 : Theme.accent)
                        .lineLimit(1)
                        .frame(minWidth: 130)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.15), value: player.lyricOffset)
                }
                .buttonStyle(.plain)
                .help("点一下复位")
                barButton("提前", icon: "forward.fill", leading: false) { player.adjustLyricOffset(by: step) }
                    .help("歌词提前 0.25 秒（歌词慢了）⌥⌘]")
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { player.adjustingLyrics = false }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.accent))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("调好了，收起（每次调整当时就已保存）")
            }
        }
    }

    private func barButton(_ title: String, icon: String, leading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if leading { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.ui(13, .bold))
                if !leading { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(Theme.surface))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
