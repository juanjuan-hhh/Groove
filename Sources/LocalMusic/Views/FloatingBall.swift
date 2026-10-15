import AppKit
import SwiftUI

/// 悬浮球模式（像 QQ 音乐的迷你模式）：主窗口收起，屏幕上留一个圆形的小球。
/// 封面跟着播放慢慢转，外圈是进度环；鼠标移上去出现 上一首 / 播放暂停 / 下一首 / 返回。
/// 拖动可以挪位置（会记住），双击或点程序坞图标回到主窗口。
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
    }

    func exit() {
        guard let panel, panel.isVisible else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
        panel.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        (mainWindow ?? NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }

    // MARK: 拖动（按屏幕上的鼠标位置算，窗口跟着鼠标走不会抖）

    @ObservationIgnored private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    func drag() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    func endDrag() {
        dragStart = nil
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
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
        withAnimation(.easeInOut(duration: 0.15)) { FloatingBall.shared.hovering = true }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        withAnimation(.easeInOut(duration: 0.15)) { FloatingBall.shared.hovering = false }
    }
}

struct FloatingBallView: View {
    @Environment(PlayerController.self) private var player
    private var hovering: Bool { FloatingBall.shared.hovering }
    /// 封面转角：暂停时记下转到的角度，继续播放时从这里接着转
    @State private var angleAtPause: Double = 0
    @State private var spinStart: Date?

    private let size = FloatingBall.size
    private let ring: CGFloat = 5
    private let degreesPerSecond = 18.0   // 20 秒转一圈

    var body: some View {
        let fraction = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
        ZStack {
            Circle().fill(Theme.card)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { context in
                ArtworkView(track: player.current, size: size - ring * 2 - 6, circle: true)
                    .rotationEffect(.degrees(angle(at: context.date)))
            }
            .allowsHitTesting(false)

            // 进度环
            Circle().stroke(Theme.track, lineWidth: ring).padding(ring / 2)
                .allowsHitTesting(false)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: ring, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(ring / 2)
                .allowsHitTesting(false)

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
        .onChange(of: player.isPlaying, initial: true) { _, playing in
            if playing {
                spinStart = Date()
            } else if let start = spinStart {
                angleAtPause += Date().timeIntervalSince(start) * degreesPerSecond
                spinStart = nil
            }
        }
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

    private func angle(at date: Date) -> Double {
        let running = spinStart.map { date.timeIntervalSince($0) * degreesPerSecond } ?? 0
        return (angleAtPause + running).truncatingRemainder(dividingBy: 360)
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
