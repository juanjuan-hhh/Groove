import AppKit
import SwiftUI

/// 封面图。没有封面时显示深色占位图。
struct ArtworkView: View {
    let track: Track?
    let size: CGFloat
    var cornerRadius: CGFloat = Theme.artRadius
    var circle = false

    @State private var image: NSImage?

    init(track: Track?, size: CGFloat, cornerRadius: CGFloat = Theme.artRadius, circle: Bool = false) {
        self.track = track
        self.size = size
        self.cornerRadius = cornerRadius
        self.circle = circle
        // 内存里已有的封面直接用，避免打开正在播放页时封面晚一拍「跳」出来
        _image = State(initialValue: track.flatMap { ArtworkProvider.shared.cachedImage(for: $0, size: size) })
    }

    var body: some View {
        let provider = ArtworkProvider.shared
        let taskID = "\(track?.path ?? "")#\(provider.revision)"
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.surface
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.35, weight: .medium))
                    .foregroundStyle(Theme.text3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
        .task(id: taskID) {
            guard let track else {
                image = nil
                return
            }
            image = await provider.image(for: track, size: size)
        }
    }
}

/// SQ / HR 音质标签：纯色小胶囊，SQ 赭橙、HR 芥末黄
struct QualityBadge: View {
    let quality: AudioQuality

    var body: some View {
        switch quality {
        case .sq: badge("SQ", Theme.terra)
        case .hr: badge("HR", Theme.mustard)
        case .standard: EmptyView()
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        ChipText(text: text, color: color, font: .ui(9, .heavy), hPad: 5, vPad: 1)
    }
}

/// 图标按钮
struct IconButton: View {
    let systemName: String
    var size: CGFloat = 15
    var active = true
    var help = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .opacity(active ? 1 : 0.4)
                .frame(width: size + 16, height: size + 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 睡眠定时菜单
struct SleepTimerMenu: View {
    @Environment(PlayerController.self) private var player
    var size: CGFloat = 16

    var body: some View {
        Menu {
            if let deadline = player.sleepDeadline {
                Text("将在 \(deadline.formatted(date: .omitted, time: .shortened)) 停止播放")
            } else if player.stopAfterCurrent {
                Text("将在当前歌曲播完后停止")
            }
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("\(minutes) 分钟后停止") { player.setSleepTimer(minutes: minutes) }
            }
            Button("播完当前歌曲后停止") { player.setStopAfterCurrent() }
            if player.sleepActive {
                Divider()
                Button("取消定时") { player.cancelSleepTimer() }
            }
        } label: {
            Image(systemName: player.sleepActive ? "timer.circle.fill" : "timer")
                .font(.system(size: size))
                .foregroundStyle(player.sleepActive ? Theme.accent : Theme.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("睡眠定时")
    }
}

/// 歌曲的右键菜单 / "⋯" 菜单
struct TrackMenuItems: View {
    let track: Track
    var playlistID: UUID?
    let onPlay: () -> Void

    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Button("播放", action: onPlay)
        Button("下一首播放") { player.playNext(track) }
        Button("添加到播放队列") { player.addToQueue(track) }
        Divider()
        Button(library.isFavorite(track) ? "取消收藏" : "收藏") { library.toggleFavorite(track) }
        Menu("添加到歌单") {
            ForEach(library.playlists) { playlist in
                Button(playlist.name) { library.add([track], to: playlist.id) }
            }
            if !library.playlists.isEmpty { Divider() }
            Button("新建歌单…") { library.playlistDraft = [track] }
        }
        if let playlistID {
            Button("从歌单中移除") { library.remove(track, from: playlistID) }
        }
        Divider()
        Button("联网搜索封面和歌词…") { player.openOnlineSearch(for: track) }
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }
    }
}

/// 艺术家 / 文件夹 / 歌单 列表里的一行
struct GroupRow<Leading: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let leading: () -> Leading
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            leading()
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(14, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle).font(.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
            .fill(hovering ? Theme.surface : .clear).padding(.horizontal, 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// 播放时像唱片一样慢慢转的圆形封面（正在播放页、悬浮球用）。
/// 暂停就停在原处，继续播放从停下的角度接着转；换歌时回正。齿轮菜单里可以关掉。
/// 转动交给 Core Animation（系统渲染进程负责），不用每帧重画界面，几乎不占 CPU。
struct SpinningArtwork: View {
    let track: Track?
    let size: CGFloat
    var secondsPerTurn = 20.0

    static let enabledKey = "spinCover"

    @Environment(PlayerController.self) private var player
    @AppStorage(SpinningArtwork.enabledKey) private var enabled = true
    @State private var image: NSImage?

    init(track: Track?, size: CGFloat, secondsPerTurn: Double = 20.0) {
        self.track = track
        self.size = size
        self.secondsPerTurn = secondsPerTurn
        // 内存里已有的封面直接用：打开正在播放页的第一帧就是转盘，不会先放一张静态图再「跳」成转盘
        _image = State(initialValue: track.flatMap { ArtworkProvider.shared.cachedImage(for: $0, size: size) })
    }

    var body: some View {
        let provider = ArtworkProvider.shared
        ZStack {
            if let image, enabled {
                SpinLayer(image: image, size: size, spinning: player.isPlaying,
                          trackID: track?.id ?? "", secondsPerTurn: secondsPerTurn)
            } else {
                ArtworkView(track: track, size: size, circle: true)   // 关掉旋转或没封面时：正着放
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(track?.path ?? "")#\(provider.revision)") {
            guard let track else {
                image = nil
                return
            }
            image = provider.cachedImage(for: track, size: size)
            image = await provider.image(for: track, size: size)
        }
    }
}

private struct SpinLayer: NSViewRepresentable {
    let image: NSImage
    let size: CGFloat
    let spinning: Bool
    let trackID: String
    let secondsPerTurn: Double

    func makeNSView(context: Context) -> SpinView {
        SpinView(frame: NSRect(x: 0, y: 0, width: size, height: size))   // 一开始就是最终大小
    }

    func updateNSView(_ view: SpinView, context: Context) {
        view.update(image: image, trackID: trackID, spinning: spinning, secondsPerTurn: secondsPerTurn)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpinView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    final class SpinView: NSView {
        private let disc = CALayer()
        private var trackID = ""
        private var spinning = false
        private static let key = "spin"

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            disc.contentsGravity = .resizeAspectFill
            disc.masksToBounds = true
            // 换图、改大小时不要系统默认的淡入 / 缩放动画（否则打开页面时封面会「跳」一下）
            disc.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
            disc.bounds = bounds
            disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
            disc.cornerRadius = bounds.width / 2
            disc.contentsScale = NSScreen.main?.backingScaleFactor ?? 2   // 第一帧就清晰
            layer?.addSublayer(disc)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // 点击交给外面的 SwiftUI

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            disc.bounds = bounds
            disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
            disc.cornerRadius = bounds.width / 2
            CATransaction.commit()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            disc.contentsScale = window?.backingScaleFactor ?? 2
        }

        func update(image: NSImage, trackID: String, spinning: Bool, secondsPerTurn: Double) {
            disc.contents = image
            if trackID != self.trackID || disc.animation(forKey: Self.key) == nil {
                // 换歌：回正，重新开始
                self.trackID = trackID
                disc.removeAnimation(forKey: Self.key)
                disc.speed = 1
                disc.timeOffset = 0
                disc.beginTime = 0
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi   // 顺时针
                spin.duration = secondsPerTurn
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                disc.add(spin, forKey: Self.key)
                self.spinning = true
                if !spinning { pause() }
            } else if spinning != self.spinning {
                spinning ? resume() : pause()
            }
        }

        /// 停在当前角度
        private func pause() {
            guard spinning else { return }
            spinning = false
            let now = disc.convertTime(CACurrentMediaTime(), from: nil)
            disc.speed = 0
            disc.timeOffset = now
        }

        /// 从停下的角度接着转
        private func resume() {
            guard !spinning else { return }
            spinning = true
            let paused = disc.timeOffset
            disc.speed = 1
            disc.timeOffset = 0
            disc.beginTime = 0
            disc.beginTime = disc.convertTime(CACurrentMediaTime(), from: nil) - paused
        }
    }
}

/// 正在播放的那首歌旁边的三根小音柱：播放时高低错开地跳，暂停时停住。
/// 跳动交给 Core Animation（系统渲染进程负责），和旋转封面一样，App 自己几乎不占 CPU（和 iPhone 版一样）
struct PlayingBars: View {
    let isPlaying: Bool
    var color: Color = Theme.accent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        BarsLayer(isPlaying: isPlaying, color: NSColor(color), scheme: scheme)
            .frame(width: 14, height: 14)
            .accessibilityLabel(isPlaying ? "正在播放" : "已暂停")
    }
}

private struct BarsLayer: NSViewRepresentable {
    let isPlaying: Bool
    let color: NSColor
    let scheme: ColorScheme

    func makeNSView(context: Context) -> BarsView { BarsView(frame: NSRect(x: 0, y: 0, width: 14, height: 14)) }

    func updateNSView(_ view: BarsView, context: Context) {
        view.update(isPlaying: isPlaying, color: color)
    }

    final class BarsView: NSView {
        private var bars: [CALayer] = []
        private var playing: Bool?
        private static let key = "bounce"
        /// 每根柱子的高度变化（占满高的比例）和一轮的时长，三根各不相同，看起来不机械
        private static let patterns: [[CGFloat]] = [
            [0.35, 1.0, 0.55, 0.85, 0.35],
            [1.0, 0.4, 0.8, 0.3, 1.0],
            [0.55, 0.8, 0.3, 1.0, 0.55],
        ]
        private static let durations: [CFTimeInterval] = [1.3, 1.1, 1.5]
        /// 暂停时停住的高度
        private static let resting: [CGFloat] = [0.45, 0.75, 0.35]

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for _ in 0..<3 {
                let bar = CALayer()
                bar.anchorPoint = CGPoint(x: 0.5, y: 0)   // Mac 坐标原点在左下：从底部往上伸缩
                bar.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull(),
                               "backgroundColor": NSNull()]
                layer?.addSublayer(bar)
                bars.append(bar)
            }
            layoutBars()
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            layoutBars()
        }

        private func layoutBars() {
            let width: CGFloat = 3, gap: CGFloat = 2.5
            let total = width * 3 + gap * 2
            let x0 = (bounds.width - total) / 2
            for (i, bar) in bars.enumerated() {
                bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
                bar.position = CGPoint(x: x0 + CGFloat(i) * (width + gap) + width / 2, y: 0)
                bar.cornerRadius = width / 2
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 重新显示时动画可能被系统移除了，补上
            if window != nil, playing == true, bars.first?.animation(forKey: Self.key) == nil {
                startBouncing()
            }
        }

        func update(isPlaying: Bool, color: NSColor) {
            // 深色 / 浅色两版颜色：按这个视图当前的外观取
            var cg = color.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
            bars.forEach { $0.backgroundColor = cg }
            guard isPlaying != playing else { return }
            playing = isPlaying
            if isPlaying {
                startBouncing()
            } else {
                for (i, bar) in bars.enumerated() {
                    bar.removeAnimation(forKey: Self.key)
                    bar.transform = CATransform3DMakeScale(1, Self.resting[i], 1)
                }
            }
        }

        private func startBouncing() {
            for (i, bar) in bars.enumerated() {
                bar.transform = CATransform3DIdentity
                let anim = CAKeyframeAnimation(keyPath: "transform.scale.y")
                anim.values = Self.patterns[i]
                anim.duration = Self.durations[i]
                anim.repeatCount = .infinity
                anim.calculationMode = .cubic
                anim.isRemovedOnCompletion = false
                bar.add(anim, forKey: Self.key)
            }
        }
    }
}
