import AppKit
import SwiftUI

/// 悬浮球模式（像 QQ 音乐的迷你模式）：主窗口收起，屏幕上留一个圆形的小球。
/// 封面跟着播放慢慢转，外圈是进度环；鼠标移上去出现 上一首 / 播放暂停 / 下一首 / 返回。
/// 拖动可以挪位置（会记住），拖到左右边缘会贴边并藏起一半；双击或点程序坞图标回到主窗口。
@MainActor
@Observable
final class FloatingBall {
    static let shared = FloatingBall()

    static let size: CGFloat = 96
    private static let originKey = "floatingBallOrigin"

    /// 鼠标是否在球上（用 AppKit 的跟踪区域检测，Groove 不在前台时也有效）
    var hovering = false

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private weak var mainWindow: NSWindow?

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle(player: PlayerController) {
        isShown ? exit() : enter(player: player)
    }

    func enter(player: PlayerController) {
        guard !isShown else { return }
        mainWindow = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }
        let panel = self.panel ?? makePanel(player: player)
        self.panel = panel
        panel.setFrameOrigin(savedOrigin())
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        mainWindow?.orderOut(nil)
        tucked = false
        updateDock(for: panel.frame)
        scheduleTuck(after: 1.5)
    }

    func exit() {
        guard let panel, panel.isVisible else { return }
        cancelTuck()
        UserDefaults.standard.set(NSStringFromPoint((tucked ? shownFrame : nil)?.origin ?? panel.frame.origin),
                                  forKey: Self.originKey)
        tucked = false
        panel.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        (mainWindow ?? NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }

    // MARK: 拖动（按屏幕上的鼠标位置算，窗口跟着鼠标走不会抖）

    @ObservationIgnored private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    func drag() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (mouse, panel.frame.origin)
            cancelTuck()
            dock = nil
            tucked = false
        }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    func endDrag() {
        dragStart = nil
        guard let panel else { return }
        let target = snapped(panel.frame, on: panel.screen ?? NSScreen.main)
        if target != panel.frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        }
        UserDefaults.standard.set(NSStringFromPoint(target.origin), forKey: Self.originKey)
        updateDock(for: target)
        if !hovering { scheduleTuck(after: 0.8) }
    }

    // MARK: 贴边藏一半（像 QQ 音乐）：贴在左右边时，鼠标离开一会儿就滑出去一半，移上去再滑回来

    enum DockEdge { case left, right }

    @ObservationIgnored private var dock: DockEdge?
    /// 贴边时完整露出来的位置
    @ObservationIgnored private var shownFrame: NSRect?
    @ObservationIgnored private var tucked = false
    /// 藏起一半时贴在哪边（界面据此改成「半圆进度 + 播放状态」），露出来时为 nil
    private(set) var tuckedEdge: DockEdge?
    @ObservationIgnored private var tuckTask: Task<Void, Never>?

    func pointerEntered() {
        withAnimation(.easeInOut(duration: 0.15)) { hovering = true }
        cancelTuck()
        if tucked { slide(to: shownFrame, tucked: false) }
    }

    func pointerExited() {
        withAnimation(.easeInOut(duration: 0.15)) { hovering = false }
        if dragStart == nil { scheduleTuck(after: 0.8) }
    }

    /// 贴在左 / 右边、而且那一侧没有别的显示器时，才算「贴边」
    private func updateDock(for frame: NSRect) {
        dock = nil
        shownFrame = frame
        guard let screen = panel?.screen ?? NSScreen.main else { return }
        let lo = screen.visibleFrame.insetBy(dx: Self.edgeGap, dy: Self.edgeGap)
        let mid = frame.midY
        func neighbor(atX x: CGFloat) -> Bool {
            NSScreen.screens.contains { $0 != screen && $0.frame.contains(NSPoint(x: x, y: mid)) }
        }
        if abs(frame.minX - lo.minX) < 1, !neighbor(atX: screen.frame.minX - 2) {
            dock = .left
        } else if abs(frame.maxX - lo.maxX) < 1, !neighbor(atX: screen.frame.maxX + 2) {
            dock = .right
        }
    }

    private func scheduleTuck(after seconds: Double) {
        cancelTuck()
        guard dock != nil, !tucked else { return }
        tuckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.hovering, self.dragStart == nil else { return }
            self.tuck()
        }
    }

    private func cancelTuck() {
        tuckTask?.cancel()
        tuckTask = nil
    }

    /// 滑出去一半，只露半个球
    private func tuck() {
        guard let dock, var frame = shownFrame, let screen = panel?.screen ?? NSScreen.main else { return }
        let edge = screen.visibleFrame
        frame.origin.x = dock == .left ? edge.minX - frame.width / 2 : edge.maxX - frame.width / 2
        slide(to: frame, tucked: true)
    }

    private func slide(to frame: NSRect?, tucked: Bool) {
        guard let panel, let frame else { return }
        self.tucked = tucked
        withAnimation(.easeInOut(duration: 0.2)) { tuckedEdge = tucked ? dock : nil }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// 离屏幕边缘（菜单栏下、程序坞以外）不到这么远就贴过去
    private static let snapDistance: CGFloat = 48
    /// 贴边后和边缘留的空隙
    private static let edgeGap: CGFloat = 6

    /// 贴边：靠近哪条边就贴到哪条边（靠近角落就贴到角落）；拖出屏幕的部分拉回来
    private func snapped(_ frame: NSRect, on screen: NSScreen?) -> NSRect {
        guard let area = screen?.visibleFrame else { return frame }
        var f = frame
        let lo = area.insetBy(dx: Self.edgeGap, dy: Self.edgeGap)
        if f.minX - lo.minX < Self.snapDistance { f.origin.x = lo.minX }
        if lo.maxX - f.maxX < Self.snapDistance { f.origin.x = lo.maxX - f.width }
        if f.minY - lo.minY < Self.snapDistance { f.origin.y = lo.minY }
        if lo.maxY - f.maxY < Self.snapDistance { f.origin.y = lo.maxY - f.height }
        return f
    }

    private func makePanel(player: PlayerController) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        let host = FirstClickHostingView(rootView: FloatingBallView().environment(player).modifier(ThemedAppearance()))
        host.frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        panel.contentView = host
        return panel
    }

    /// 上次的位置；第一次放在屏幕右下角
    private func savedOrigin() -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let text = UserDefaults.standard.string(forKey: Self.originKey) {
            let p = NSPointFromString(text)
            // 换了显示器之类导致跑到屏幕外时，放回默认位置
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(NSRect(origin: p, size: CGSize(width: Self.size, height: Self.size))) }) {
                return p
            }
        }
        return NSPoint(x: screen.maxX - Self.size - 40, y: screen.minY + 120)
    }
}

/// 悬浮球不抢焦点，但第一次点就要响应（不用先点一下激活）；
/// 鼠标进出用一直有效的跟踪区域检测，在别的 App 前台时也能显示按钮
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["ball"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["ball": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        FloatingBall.shared.pointerEntered()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        FloatingBall.shared.pointerExited()
    }
}

struct FloatingBallView: View {
    @Environment(PlayerController.self) private var player
    private var hovering: Bool { FloatingBall.shared.hovering }

    private let size = FloatingBall.size
    private let ring: CGFloat = 5

    var body: some View {
        let fraction = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
        ZStack {
            Circle().fill(Theme.card)
            if let edge = FloatingBall.shared.tuckedEdge {
                tuckedFace(edge: edge, fraction: fraction)
                    .transition(.opacity)
            } else {
                Group {
                    SpinningArtwork(track: player.current, size: size - ring * 2 - 6)

                    // 进度环
                    Circle().stroke(Theme.track, lineWidth: ring).padding(ring / 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: ring, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(ring / 2)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if hovering { controls.transition(.opacity) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .contentShape(Circle())
        // 按住拖动挪位置，双击回主窗口；上面的按钮优先响应自己的点击
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in FloatingBall.shared.drag() }
                .onEnded { _ in FloatingBall.shared.endDrag() }
        )
        .onTapGesture(count: 2) { FloatingBall.shared.exit() }
        .contextMenu {
            if let track = player.current {
                Text("\(track.title) — \(track.artist)")
                Divider()
            }
            Button(player.isPlaying ? "暂停" : "播放") { player.togglePlayPause() }
            Button("上一首") { player.previous() }
            Button("下一首") { player.next() }
            Divider()
            Button("返回主窗口") { FloatingBall.shared.exit() }
        }
        .help(player.current.map { "\($0.title) — \($0.artist)\n双击回到主窗口" } ?? "双击回到主窗口")
    }

    /// 藏起一半时的样子（Porthole / App 图标的元素）：不显示封面；
    /// 露出来的半圆边是整条进度（从上到下），进度头上有个小光点，里面一圈石板蓝细环；
    /// 中间播放时是三根跳动的音柱，暂停时是播放三角
    private func tuckedFace(edge: FloatingBall.DockEdge, fraction: Double) -> some View {
        // 贴右边时露出左半边，进度从顶部沿左边走到底部；贴左边时反过来
        let mirror: CGFloat = edge == .right ? -1 : 1
        let inner: CGFloat = ring + 9
        return ZStack {
            halfArc(to: 1, color: Theme.track, width: ring, inset: ring / 2, mirror: mirror)
            halfArc(to: fraction, color: Theme.accent, width: ring, inset: ring / 2, mirror: mirror)
            halfArc(to: 1, color: Theme.slate, width: 2, inset: inner, mirror: mirror)
            progressDot(fraction: fraction, mirror: mirror)

            Group {
                if player.isPlaying {
                    EqualizerBars()
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .offset(x: mirror * size / 4 + (edge == .right ? 10 : -10))   // 往球心挪一点，离蓝圈远些
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: player.isPlaying)
        .allowsHitTesting(false)
    }

    /// 从顶部开始、沿露出来的那半边走的半圆弧，to 是 0…1
    private func halfArc(to value: Double, color: Color, width: CGFloat, inset: CGFloat, mirror: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: 0.5 * max(0, min(1, value)))
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .scaleEffect(x: mirror, y: 1)
            .padding(inset)
    }

    /// 进度头上的小光点
    private func progressDot(fraction: Double, mirror: CGFloat) -> some View {
        let r = size / 2 - ring / 2
        let theta = Double.pi * max(0, min(1, fraction))
        return Circle()
            .fill(Theme.shine)
            .frame(width: 5, height: 5)
            .shadow(color: Theme.accent.opacity(0.8), radius: 3)
            .offset(x: mirror * r * CGFloat(sin(theta)), y: -r * CGFloat(cos(theta)))
            .opacity(fraction > 0.01 ? 1 : 0)
    }

    /// 鼠标移上去时的按钮
    private var controls: some View {
        ZStack {
            Circle().fill(Theme.bg.opacity(0.62)).allowsHitTesting(false)
            HStack(spacing: 4) {
                ballButton("backward.end.fill", 11, help: "上一首") { player.previous() }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .offset(x: player.isPlaying ? 0 : 1)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.accent))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(player.isPlaying ? "暂停" : "播放")
                ballButton("forward.end.fill", 11, help: "下一首") { player.next() }
            }
            VStack {
                ballButton("arrow.up.left.and.arrow.down.right", 9, help: "返回主窗口") { FloatingBall.shared.exit() }
                    .padding(.top, 10)
                Spacer()
            }
        }
    }

    private func ballButton(_ symbol: String, _ size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}


/// 三根跳动的音柱（赭橙 / 芥末黄 / 鼠尾草绿），悬浮球藏起一半、正在播放时显示
private struct EqualizerBars: View {
    private let colors = [Theme.terra, Theme.mustard, Theme.sage]
    private let speeds = [5.1, 6.7, 4.3]
    private let phases = [0.0, 1.3, 2.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(colors[i])
                        .frame(width: 4, height: 6 + 12 * abs(sin(t * speeds[i] + phases[i])))
                }
            }
            .frame(height: 18, alignment: .bottom)
        }
    }
}
