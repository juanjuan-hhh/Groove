import AppKit
import SwiftUI

/// 悬浮球模式（像 QQ 音乐的迷你模式）：主窗口收起，屏幕上留一个圆形的小球。
/// 封面跟着播放慢慢转，外圈是进度环；鼠标移上去出现 上一首 / 播放暂停 / 下一首 / 返回。
/// 拖动可以挪位置（会记住），拖到左右边缘会贴边并藏起一半；双击或点程序坞图标回到主窗口。
@MainActor
@Observable
final class FloatingBall {
    static let shared = FloatingBall()

    /// 默认大小；设置里可以在 sizeRange 之间调（记在 sizeKey 里）
    static let defaultSize: CGFloat = 96
    static let sizeRange: ClosedRange<CGFloat> = 64...160
    static let sizeKey = "floatingBallSize"
    static var size: CGFloat {
        let saved = UserDefaults.standard.double(forKey: sizeKey)
        return saved > 0 ? min(sizeRange.upperBound, max(sizeRange.lowerBound, saved)) : defaultSize
    }
    /// 贴边藏起一半时的大小：和完整的球一样大
    static var tuckedSize: CGFloat { size }
    /// 现在球画多大（藏起一半时变小），界面跟着它变
    private(set) var ballSize: CGFloat = FloatingBall.size
    /// 球的大小相对默认的比例，歌词条按它一起缩放
    private(set) var scale: CGFloat = FloatingBall.size / FloatingBall.defaultSize
    /// 正在调大小：不贴边藏起来
    @ObservationIgnored private var adjustingSize = false
    /// 正在调歌词胶囊大小：没歌词时也显示一条示例，方便看大小
    private(set) var adjustingLyric = false

    /// 「自动贴边」：拖到屏幕边上会吸过去、停一会儿藏起一半（默认开）
    static let autoDockKey = "floatingBallAutoDock"
    static var autoDock: Bool { UserDefaults.standard.object(forKey: autoDockKey) as? Bool ?? true }

    /// 「始终置顶」：球（和歌词胶囊、播放队列）一直在所有窗口上面；关掉后是普通窗口，会被别的窗口盖住（默认开）
    static let onTopKey = "floatingBallOnTop"
    static var onTop: Bool { UserDefaults.standard.object(forKey: onTopKey) as? Bool ?? true }
    static var windowLevel: NSWindow.Level { onTop ? .statusBar : .normal }

    func setOnTop(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.onTopKey)
        for window in [panel, lyricPanel, queuePanel].compactMap({ $0 }) { window.level = Self.windowLevel }
        if let panel, panel.isVisible { panel.orderFrontRegardless() }
    }

    /// 「一直显示悬浮球」：主窗口开着时悬浮球也在
    static let alwaysKey = "floatingBallAlways"
    static var alwaysOn: Bool { UserDefaults.standard.bool(forKey: alwaysKey) }

    /// 歌词胶囊相对默认的大小（0.7 = 70%），字号、留白、最大宽度一起缩放
    static let lyricSizeKey = "floatingLyricSize"
    static let lyricSizeRange: ClosedRange<CGFloat> = 0.7...1.6
    static var lyricSize: CGFloat {
        let saved = UserDefaults.standard.double(forKey: lyricSizeKey)
        return saved > 0 ? min(lyricSizeRange.upperBound, max(lyricSizeRange.lowerBound, saved)) : 1
    }
    /// 歌词胶囊实际的缩放：跟着球的大小，再乘上自己的大小
    private(set) var lyricScale: CGFloat = FloatingBall.size / FloatingBall.defaultSize * FloatingBall.lyricSize
    private static let originKey = "floatingBallOrigin"

    /// 鼠标是否在球上（用 AppKit 的跟踪区域检测，Groove 不在前台时也有效）
    var hovering = false

    @ObservationIgnored private var panel: NSPanel?
    /// 旁边的歌词条（单独的小窗口，挂在球的窗口上，跟着球一起动；不接收鼠标，不挡拖动）
    @ObservationIgnored private var lyricPanel: NSPanel?
    /// 歌词条往左伸（球在屏幕右半边时）还是往右伸
    private(set) var lyricOnLeft = true
    @ObservationIgnored private weak var mainWindow: NSWindow?

    var isShown: Bool { panel?.isVisible ?? false }

    /// 主窗口被悬浮球模式收起来了
    private var mainHidden: Bool {
        !NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }
    }

    func toggle(player: PlayerController) {
        (isShown && mainHidden) ? exit() : enter(player: player)
    }

    /// 切到悬浮球模式：放出悬浮球，收起主窗口
    func enter(player: PlayerController) {
        if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }) {
            mainWindow = window
        }
        show(player: player)
        mainWindow?.orderOut(nil)
    }

    /// 「一直显示悬浮球」开关
    func setAlwaysOn(_ on: Bool, player: PlayerController) {
        UserDefaults.standard.set(on, forKey: Self.alwaysKey)
        if on {
            show(player: player)
        } else if isShown && !mainHidden {
            hideBall()
        }
    }

    /// 「自动贴边」开关：关掉时藏着一半的球先露出来
    func setAutoDock(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.autoDockKey)
        guard let panel, panel.isVisible else { return }
        cancelTuck()
        let frame = tucked ? (shownFrame ?? panel.frame) : panel.frame
        if tucked { slide(to: frame, tucked: false) }
        updateDock(for: frame)
        if on {
            let target = snapped(frame, on: panel.screen ?? NSScreen.main)
            if target != frame { panel.setFrame(target, display: true); positionLyricPanel(for: target) }
            updateDock(for: target)
            if !hovering { scheduleTuck(after: 0.8) }
        }
    }

    /// 只放出悬浮球（不动主窗口）
    func show(player: PlayerController) {
        guard !isShown else { return }
        let panel = self.panel ?? makePanel(player: player)
        self.panel = panel
        panel.setFrameOrigin(savedOrigin())
        panel.hasShadow = true
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        attachLyricPanel(player: player)
        tucked = false
        tuckedEdge = nil   // 一出来是完整的球（转动的封面），等藏进去时才换成半圆的样子
        ballSize = Self.size
        scale = Self.size / Self.defaultSize
        lyricScale = scale * Self.lyricSize
        panel.setContentSize(NSSize(width: Self.size, height: Self.size))
        updateDock(for: panel.frame)
        scheduleTuck(after: 1.5)
        installMouseMonitor()
    }

    /// 回到主窗口。一直显示悬浮球时球留着，否则收起来
    func exit() {
        if !Self.alwaysOn { hideBall() }
        // 主窗口可能被「−」收进程序坞、被悬浮球模式藏起来、或者被关掉了，统一交给 AppDelegate 处理
        AppDelegate.shared?.restoreMainWindow(preferred: mainWindow)
    }

    /// 悬浮球菜单里的「关闭悬浮球」：关掉「一直显示」，收起球，回到主窗口
    func close() {
        UserDefaults.standard.set(false, forKey: Self.alwaysKey)
        exit()
    }

    private func hideBall() {
        guard let panel, panel.isVisible else { return }
        closeQueue()
        cancelTuck()
        removeMouseMonitor()
        UserDefaults.standard.set(NSStringFromPoint((tucked ? shownFrame : nil)?.origin ?? panel.frame.origin),
                                  forKey: Self.originKey)
        tucked = false
        tuckedEdge = nil   // 上次藏着一半时退出：清掉，免得下次出来时完整的球显示成半圆的样子
        if let lyricPanel {
            panel.removeChildWindow(lyricPanel)
            lyricPanel.orderOut(nil)
        }
        panel.orderOut(nil)
    }

    // MARK: 拖动
    // 直接处理 AppKit 的鼠标事件（不经过 SwiftUI 手势），窗口每次鼠标移动都马上跟过去，跟手；
    // 按下时照常交给按钮，移动超过 3 像素才算拖动，松手一定会贴边、记住位置。

    @ObservationIgnored private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    @ObservationIgnored private var pressPoint: NSPoint?
    @ObservationIgnored private var mouseMonitor: Any?

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            // 本地事件监听总在主线程调用
            nonisolated(unsafe) let incoming = event
            nonisolated(unsafe) var result: NSEvent? = event
            MainActor.assumeIsolated { result = FloatingBall.shared.handle(incoming) }
            return result
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        pressPoint = nil
        dragStart = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window === panel else { return event }
        let mouse = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            pressPoint = mouse
            return event
        case .leftMouseDragged:
            guard let press = pressPoint else { return event }
            if dragStart == nil {
                guard hypot(mouse.x - press.x, mouse.y - press.y) >= 3 else { return event }
                beginDrag(from: press)
            }
            moveWithMouse(mouse)
            return nil
        case .leftMouseUp:
            pressPoint = nil
            guard dragStart != nil else { return event }   // 没拖动：普通点击，照常交给按钮
            endDrag()
            // 拖完松手的位置可能正好在某个按钮上：把这次松开挪到窗口外面，按钮就不会被误点
            return NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -1000, y: -1000),
                                      modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                      windowNumber: event.windowNumber, context: nil,
                                      eventNumber: event.eventNumber, clickCount: event.clickCount,
                                      pressure: event.pressure)
        default:
            return event
        }
    }

    private func beginDrag(from press: NSPoint) {
        guard let panel else { return }
        // 还是缩小的样子就先恢复成完整大小
        if tucked, let shown = shownFrame {
            panel.setFrame(shown, display: true)
            ballSize = Self.size
        }
        dragStart = (press, panel.frame.origin)
        panel.hasShadow = true
        cancelTuck()
        dock = nil
        tucked = false
        withAnimation(.easeInOut(duration: 0.15)) { tuckedEdge = nil }
    }

    private func moveWithMouse(_ mouse: NSPoint) {
        guard let panel, let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
        // 拖过屏幕中线时歌词条换到另一边
        if lyricSide(for: panel.frame) != lyricOnLeft { positionLyricPanel(for: panel.frame) }
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
            } completionHandler: {
                // 歌词条挂在球上会跟着一起挪，动画完再按最终位置对齐一次
                MainActor.assumeIsolated { FloatingBall.shared.positionLyricPanel(for: target) }
            }
        } else {
            positionLyricPanel(for: target)
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
        guard Self.autoDock else { return }
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
        guard dock != nil, !tucked, !adjustingSize else { return }
        tuckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.hovering, self.dragStart == nil, !self.adjustingSize else { return }
            self.tuck()
        }
    }

    private func cancelTuck() {
        tuckTask?.cancel()
        tuckTask = nil
    }

    /// 缩小一点、滑出去一半，只露半个球（上下中心不变）
    private func tuck() {
        guard let dock, let shown = shownFrame, let screen = panel?.screen ?? NSScreen.main else { return }
        let edge = screen.visibleFrame
        let side = Self.tuckedSize
        let frame = NSRect(x: dock == .left ? edge.minX - side / 2 : edge.maxX - side / 2,
                           y: shown.midY - side / 2, width: side, height: side)
        slide(to: frame, tucked: true)
    }

    private func slide(to frame: NSRect?, tucked: Bool) {
        guard let panel, let frame else { return }
        self.tucked = tucked
        // 藏起一半时底是半透明的，窗口阴影会从底下透出来变成一块灰，所以先关掉阴影
        panel.hasShadow = !tucked
        withAnimation(.easeInOut(duration: 0.22)) {
            tuckedEdge = tucked ? dock : nil
            ballSize = frame.width
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: {
            // 歌词条跟着球一起挪过了，滑完以后再按球现在的位置对齐一次（贴边时也可能显示歌词条）
            MainActor.assumeIsolated { FloatingBall.shared.positionLyricPanel(for: frame) }
        }
    }

    /// 离屏幕边缘（菜单栏下、程序坞以外）不到这么远就贴过去
    private static let snapDistance: CGFloat = 64
    /// 贴边后和边缘留的空隙
    private static let edgeGap: CGFloat = 6

    /// 贴边：靠近哪条边就贴到哪条边（靠近角落就贴到角落）；拖出屏幕的部分拉回来
    private func snapped(_ frame: NSRect, on screen: NSScreen?) -> NSRect {
        guard let area = screen?.visibleFrame else { return frame }
        var f = frame
        let lo = area.insetBy(dx: Self.edgeGap, dy: Self.edgeGap)
        // 不自动贴边：只保证不出屏幕
        guard Self.autoDock else {
            f.origin.x = min(max(f.minX, area.minX), area.maxX - f.width)
            f.origin.y = min(max(f.minY, area.minY), area.maxY - f.height)
            return f
        }
        if f.minX - lo.minX < Self.snapDistance { f.origin.x = lo.minX }
        if lo.maxX - f.maxX < Self.snapDistance { f.origin.x = lo.maxX - f.width }
        if f.minY - lo.minY < Self.snapDistance { f.origin.y = lo.minY }
        if lo.maxY - f.maxY < Self.snapDistance { f.origin.y = lo.maxY - f.height }
        return f
    }

    // MARK: 调大小（设置菜单里的「悬浮球大小…」）

    @ObservationIgnored private var sizePanel: NSPanel?
    /// 打开调大小窗口之前悬浮球是不是已经开着（关掉窗口时恢复）
    @ObservationIgnored private var shownBeforeAdjusting = false

    enum Adjust { case ball, lyric }

    /// 打开调大小的小窗口（悬浮球 / 歌词胶囊），同时把悬浮球放出来，边拖滑块边看
    func showSizeAdjuster(player: PlayerController, _ kind: Adjust = .ball) {
        if let sizePanel, sizePanel.isVisible { sizePanel.orderOut(nil) }
        if !adjustingSize { shownBeforeAdjusting = isShown }
        adjustingSize = true
        adjustingLyric = kind == .lyric
        cancelTuck()
        if isShown {
            if tucked { slide(to: shownFrame, tucked: false) }
        } else {
            enter(player: player)
        }
        let window = makeSizePanel(kind)
        sizePanel = window
        if let screen = (panel?.screen ?? NSScreen.main)?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.midX - window.frame.width / 2, y: screen.midY - window.frame.height / 2))
        }
        window.orderFrontRegardless()
        window.invalidateShadow()
    }

    /// 调大小卡片点了「完成」：之前没开悬浮球就回主窗口，开着就留着
    fileprivate func closeSizeAdjuster() {
        sizePanel?.orderOut(nil)
        adjustingSize = false
        adjustingLyric = false
        if shownBeforeAdjusting {
            scheduleTuck(after: 1.5)
        } else {
            exit()
        }
    }

    /// 改大小：记下来，球按中心放大缩小（靠边的话还贴着边），歌词条跟着一起变
    func setSize(_ value: CGFloat) {
        let size = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, value.rounded()))
        UserDefaults.standard.set(Double(size), forKey: Self.sizeKey)
        scale = size / Self.defaultSize
        lyricScale = scale * Self.lyricSize
        guard let panel, panel.isVisible, !tucked else {
            ballSize = size
            return
        }
        let old = panel.frame
        var frame = NSRect(x: old.midX - size / 2, y: old.midY - size / 2, width: size, height: size)
        frame = snapped(frame, on: panel.screen ?? NSScreen.main)
        ballSize = size
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
        positionLyricPanel(for: frame)
        updateDock(for: frame)
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }

    /// 改歌词胶囊大小：记下来，胶囊马上跟着变
    func setLyricSize(_ value: CGFloat) {
        let v = min(Self.lyricSizeRange.upperBound, max(Self.lyricSizeRange.lowerBound, value))
        UserDefaults.standard.set(Double(v), forKey: Self.lyricSizeKey)
        lyricScale = scale * v
        if let panel { positionLyricPanel(for: tucked ? (shownFrame ?? panel.frame) : panel.frame) }
    }

    /// 无边框的小卡片（和 App 里其他卡片一样的配色），不抢焦点
    private func makeSizePanel(_ kind: Adjust) -> NSPanel {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 130),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        let card: FloatingBallSizeView
        switch kind {
        case .ball:
            card = FloatingBallSizeView(title: "悬浮球大小", range: Self.sizeRange, defaultValue: Self.defaultSize,
                                        initial: Self.size, label: { "\(Int($0))" },
                                        apply: { FloatingBall.shared.setSize($0) },
                                        done: { FloatingBall.shared.closeSizeAdjuster() })
        case .lyric:
            card = FloatingBallSizeView(title: "歌词胶囊大小", range: Self.lyricSizeRange, defaultValue: 1,
                                        initial: Self.lyricSize, label: { "\(Int(($0 * 100).rounded()))%" },
                                        apply: { FloatingBall.shared.setLyricSize($0) },
                                        done: { FloatingBall.shared.closeSizeAdjuster() })
        }
        let host = ClickThroughHostingView(rootView: card.modifier(ThemedAppearance()))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        return window
    }

    // MARK: 右键菜单

    @ObservationIgnored private weak var menuPlayer: PlayerController?

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, checked: Bool = false, enabled: Bool = true, _ action: @escaping () -> Void) -> NSMenuItem {
            let it = ClosureMenuItem(title: title, action: action)
            it.state = checked ? .on : .off
            it.isEnabled = enabled
            return it
        }
        guard let player = menuPlayer else { return menu }
        menu.addItem(item("打开主窗口") { FloatingBall.shared.exit() })
        menu.addItem(.separator())
        if let track = player.current {
            let info = NSMenuItem(title: "\(track.title) — \(track.artist)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(item(player.isPlaying ? "暂停" : "播放") { player.togglePlayPause() })
        menu.addItem(item("上一首") { player.previous() })
        menu.addItem(item("下一首") { player.next() })
        menu.addItem(.separator())
        menu.addItem(item("悬浮球大小…") { FloatingBall.shared.showSizeAdjuster(player: player, .ball) })
        menu.addItem(item("歌词胶囊大小…") { FloatingBall.shared.showSizeAdjuster(player: player, .lyric) })
        let lyricsItem = NSMenuItem(title: "悬浮球歌词", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let mode = FloatingLyricsMode(rawValue: UserDefaults.standard.string(forKey: FloatingLyricsMode.key) ?? "") ?? .always
        for m in FloatingLyricsMode.allCases {
            sub.addItem(item(m.label, checked: m == mode) { UserDefaults.standard.set(m.rawValue, forKey: FloatingLyricsMode.key) })
        }
        lyricsItem.submenu = sub
        menu.addItem(lyricsItem)
        menu.addItem(item("显示两行歌词", checked: Self.twoLines, enabled: mode != .off) {
            FloatingBall.shared.setTwoLines(!FloatingBall.twoLines)
        })
        let whenTucked = UserDefaults.standard.bool(forKey: FloatingLyricsMode.whenTuckedKey)
        menu.addItem(item("贴边时也显示歌词", checked: whenTucked, enabled: mode != .off) {
            UserDefaults.standard.set(!whenTucked, forKey: FloatingLyricsMode.whenTuckedKey)
        })
        menu.addItem(item("始终置顶", checked: Self.onTop) {
            FloatingBall.shared.setOnTop(!FloatingBall.onTop)
        })
        menu.addItem(item("自动贴边", checked: Self.autoDock) {
            FloatingBall.shared.setAutoDock(!FloatingBall.autoDock)
        })
        menu.addItem(item("一直显示悬浮球", checked: Self.alwaysOn) {
            FloatingBall.shared.setAlwaysOn(!FloatingBall.alwaysOn, player: player)
        })
        menu.addItem(.separator())
        menu.addItem(item("关闭悬浮球") { FloatingBall.shared.close() })
        return menu
    }

    // MARK: 播放队列（单击球显示）

    @ObservationIgnored private var queuePanel: NSPanel?
    @ObservationIgnored private var queueMonitors: [Any] = []

    func toggleQueue() {
        if let queuePanel, queuePanel.isVisible { closeQueue() } else { showQueue() }
    }

    private func showQueue() {
        guard let panel, let player = menuPlayer else { return }
        let queue = queuePanel ?? makeQueuePanel(player: player)
        queuePanel = queue
        // 每次打开都换一个新的列表，重新滚到正在放的那首
        queue.contentView = makeQueueHost(player: player)
        // 放在球朝屏幕里面的那一边，上下尽量和球对齐，不出屏幕
        let ball = tucked ? (shownFrame ?? panel.frame) : panel.frame
        let size = queue.frame.size
        let area = (panel.screen ?? NSScreen.main)?.visibleFrame ?? ball
        var x = lyricSide(for: ball) ? ball.minX - 10 - size.width : ball.maxX + 10
        var y = ball.midY - size.height / 2
        x = min(max(x, area.minX + 8), area.maxX - size.width - 8)
        y = min(max(y, area.minY + 8), area.maxY - size.height - 8)
        queue.setFrameOrigin(NSPoint(x: x, y: y))
        queue.orderFrontRegardless()
        cancelTuck()
        // 点队列外面（包括别的 App）就收起来
        let close: (NSEvent) -> Void = { event in
            MainActor.assumeIsolated {
                let ball = FloatingBall.shared
                guard let q = ball.queuePanel, q.isVisible else { return }
                if event.window === q || event.window === ball.panel { return }
                ball.closeQueue()
            }
        }
        if queueMonitors.isEmpty {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: close) {
                queueMonitors.append(m)
            }
            if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { close($0); return $0 }) {
                queueMonitors.append(m)
            }
        }
    }

    func closeQueue() {
        queuePanel?.orderOut(nil)
        queueMonitors.forEach(NSEvent.removeMonitor)
        queueMonitors = []
        if !hovering { scheduleTuck(after: 0.8) }
    }

    private func makeQueuePanel(player: PlayerController) -> NSPanel {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = Self.windowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentView = makeQueueHost(player: player)
        return window
    }

    private func makeQueueHost(player: PlayerController) -> NSView {
        let host = NSHostingView(rootView: QueueView()
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .environment(player)
            .modifier(ThemedAppearance()))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
        return host
    }

    // MARK: 歌词条

    var lyricWidth: CGFloat { 320 * lyricScale }
    var lyricHeight: CGFloat { ((Self.twoLines ? 58 : 36) * lyricScale).rounded() }

    /// 「显示两行歌词」：当前这句 + 下一句（小一点、淡一点）
    static let twoLinesKey = "floatingLyricsTwoLines"
    static var twoLines: Bool { UserDefaults.standard.bool(forKey: twoLinesKey) }

    func setTwoLines(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.twoLinesKey)
        if let panel { positionLyricPanel(for: tucked ? (shownFrame ?? panel.frame) : panel.frame) }
    }
    private var lyricGap: CGFloat { 8 * scale }

    private func attachLyricPanel(player: PlayerController) {
        guard let panel else { return }
        let lyric = lyricPanel ?? makeLyricPanel(player: player)
        lyricPanel = lyric
        positionLyricPanel(for: panel.frame)
        panel.addChildWindow(lyric, ordered: .above)
        lyric.orderFrontRegardless()
    }

    /// 球在屏幕右半边就往左伸，左半边就往右伸（朝屏幕里面）
    private func lyricSide(for ball: NSRect) -> Bool {
        let screen = panel?.screen ?? NSScreen.main
        return ball.midX > (screen?.visibleFrame.midX ?? 0)
    }

    private func positionLyricPanel(for ball: NSRect) {
        guard let lyricPanel else { return }
        let onLeft = lyricSide(for: ball)
        if onLeft != lyricOnLeft { lyricOnLeft = onLeft }
        let x = onLeft ? ball.minX - lyricGap - lyricWidth : ball.maxX + lyricGap
        // 上下和完整的球对齐（藏起一半时歌词条本来就不显示）
        let midY = tucked ? (shownFrame?.midY ?? ball.midY) : ball.midY
        lyricPanel.setFrame(NSRect(x: x, y: midY - lyricHeight / 2, width: lyricWidth, height: lyricHeight),
                            display: false)
    }

    func setLyricClickable(_ on: Bool) {
        lyricPanel?.ignoresMouseEvents = !on
    }

    private func makeLyricPanel(player: PlayerController) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: lyricWidth, height: lyricHeight),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = Self.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 双击歌词胶囊回主窗口；胶囊外面是透明的，点击会穿过去
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: FloatingLyricView().environment(player).modifier(ThemedAppearance()))
        host.frame = NSRect(x: 0, y: 0, width: lyricWidth, height: lyricHeight)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    private func makePanel(player: PlayerController) -> NSPanel {
        menuPlayer = player
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = Self.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        let host = FirstClickHostingView(rootView: FloatingBallView().environment(player).modifier(ThemedAppearance()))
        host.frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        host.autoresizingMask = [.width, .height]
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

    /// 右键菜单用 AppKit 菜单，打开时生成一次。
    /// （以前用 SwiftUI 的 contextMenu，球每 0.25 秒随进度重画，菜单跟着重建，二级菜单会闪）
    override func menu(for event: NSEvent) -> NSMenu? {
        FloatingBall.shared.makeMenu()
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(FloatingBall.shared.makeMenu(), with: event, for: self)
    }

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

    /// 藏起一半时变小
    private var size: CGFloat { FloatingBall.shared.ballSize }
    /// 进度环粗细：跟着设置里的悬浮球大小一起变粗变细（贴边缩小时不变）
    private var ring: CGFloat { 3.5 * FloatingBall.shared.scale }
    /// 进度头圆点的直径
    private var knob: CGFloat { ring * 1.8 }
    /// 进度环往里收这么多，圆点整个落在球里面，不会被圆形边缘裁掉半个
    private var ringInset: CGFloat { knob / 2 }
    /// 封面的主色：贴边藏起一半时给中间染色
    @State private var coverTint: Color?
    /// 进度环颜色：封面外圈深就用白色，浅就用黑色
    @State private var ringColor: Color = .white

    var body: some View {
        let fraction = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
        let provider = ArtworkProvider.shared
        ZStack {
            // 半透明玻璃底，透出一点封面的颜色（没封面时用很淡的底色），让进度环看得清
            // 半透明玻璃底；贴边藏起一半时不用系统玻璃（它不能调透明度），换成更透明的底色，进度环、音柱不变
            if FloatingBall.shared.tuckedEdge != nil {
                Circle().fill(Theme.card.opacity(0.06)).allowsHitTesting(false)
                Circle().fill(coverTint.map { $0.opacity(0.16) } ?? Theme.card.opacity(0.08)).allowsHitTesting(false)
            } else {
                GlassBackground(cornerRadius: size / 2)
            }
            // 封面铺满整个球，进度环直接画在封面外圈上
            if FloatingBall.shared.tuckedEdge == nil {
                SpinningArtwork(track: player.current, size: size)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            // 鼠标移上去时的暗底，压在进度环下面
            if hovering {
                Circle().fill(Theme.bg.opacity(0.62)).allowsHitTesting(false).transition(.opacity)
            }
            // 进度环和圆点画在封面、暗底上面
            if let edge = FloatingBall.shared.tuckedEdge {
                tuckedFace(edge: edge, fraction: fraction)
                    .transition(.opacity)
            } else {
                Group {
                    // 进度环：颜色跟着封面外圈的深浅（深 → 白，浅 → 黑），没播的部分同色很淡
                    Circle().stroke(ringColor.opacity(0.25), lineWidth: ring).padding(ringInset)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: ring, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(ringInset)
                    progressKnob(angle: 2 * .pi * fraction)
                        .opacity(fraction > 0.01 ? 1 : 0)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if hovering {
                controls
                    .scaleEffect(size / FloatingBall.defaultSize)
                    .transition(.opacity)
            }
        }
        .task(id: "\(player.current?.path ?? "")#\(provider.revision)") {
            guard let track = player.current else {
                coverTint = nil
                ringColor = .white
                return
            }
            let color = await provider.coverColor(for: track)
            let luminance = await provider.coverEdgeLuminance(for: track)
            withAnimation(.easeInOut(duration: 0.4)) {
                coverTint = color.map { Color(nsColor: $0) }
                ringColor = (luminance ?? 0) > 0.6 ? .black : .white
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .contentShape(Circle())
        // 拖动在 FloatingBall 里按鼠标事件处理；单击空白处显示播放队列（等双击时间过了才算单击），双击回主窗口
        .gesture(TapGesture(count: 2).onEnded { FloatingBall.shared.exit() }
            .exclusively(before: TapGesture().onEnded { FloatingBall.shared.toggleQueue() }))
        .help(player.current.map { "\($0.title) — \($0.artist)\n单击显示播放队列，双击回到主窗口" } ?? "双击回到主窗口")
    }

    /// 藏起一半时的样子（和 App 图标一样的配色）：不显示封面；
    /// 露出来的半圆边是整条进度（从上到下），进度头上有个圆点；
    /// 中间播放时是三根跳动的音柱，暂停时是播放三角
    private func tuckedFace(edge: FloatingBall.DockEdge, fraction: Double) -> some View {
        // 贴右边时露出左半边，进度从顶部沿左边走到底部；贴左边时反过来
        let mirror: CGFloat = edge == .right ? -1 : 1
        return ZStack {
            halfArc(to: 1, color: ringColor.opacity(0.25), width: ring, inset: ringInset, mirror: mirror)
            halfArc(to: fraction, color: ringColor, width: ring, inset: ringInset, mirror: mirror)
            progressKnob(angle: .pi * max(0, min(1, fraction)), mirror: mirror)
                .opacity(fraction > 0.01 ? 1 : 0)

            Group {
                if player.isPlaying {
                    EqualizerBars(color: ringColor)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(ringColor)
                }
            }
            .scaleEffect(size / 80)   // 球缩小了，音柱和三角也跟着小一点
            .offset(x: mirror * size / 4 + (edge == .right ? 1 : -1) * size * 0.1)   // 往球心挪一点
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

    /// 进度头上的圆点（像 App 图标进度环末端那个）；angle 从正上方顺时针算
    private func progressKnob(angle: Double, mirror: CGFloat = 1) -> some View {
        let r = size / 2 - ringInset
        return Circle()
            .fill(ringColor)
            .frame(width: knob, height: knob)
            .offset(x: mirror * r * CGFloat(sin(angle)), y: -r * CGFloat(cos(angle)))
    }

    /// 鼠标移上去时的按钮
    private var controls: some View {
        ZStack {
            HStack(spacing: 4) {
                ballButton("backward.end.fill", 11, help: "上一首") { player.previous() }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.bg)
                        .offset(x: player.isPlaying ? 0 : 1)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.text))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(player.isPlaying ? "暂停" : "播放")
                ballButton("forward.end.fill", 11, help: "下一首") { player.next() }
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


/// 三根跳动的音柱（和 App 图标一样的墨色 / 奶油色），悬浮球藏起一半、正在播放时显示
private struct EqualizerBars: View {
    var color: Color = Theme.text
    private let peaks: [CGFloat] = [18, 13, 16]
    private let durations = [0.42, 0.55, 0.36]   // 三根节奏不一样
    @State private var up = false

    var body: some View {
        // 每根柱子自己来回伸缩（SwiftUI 动画），不用每帧重算界面
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 4, height: up ? peaks[i] : 5)
                    .animation(.easeInOut(duration: durations[i]).repeatForever(autoreverses: true), value: up)
            }
        }
        .frame(height: 18, alignment: .bottom)
        .onAppear { up = true }
    }
}


/// 悬浮球歌词的显示方式（设置菜单里选）
enum FloatingLyricsMode: String, CaseIterable, Identifiable {
    case off, hover, always
    var id: Self { self }
    static let key = "floatingLyricsMode"
    /// 贴边藏起一半时也显示歌词条
    static let whenTuckedKey = "floatingLyricsWhenTucked"
    var label: String {
        switch self {
        case .off: return "关闭"
        case .hover: return "鼠标放置显示"
        case .always: return "始终显示"
        }
    }
}

/// 悬浮球旁边的歌词条：只显示当前这一句，换句时滑动切换
private struct FloatingLyricView: View {
    @Environment(PlayerController.self) private var player
    @AppStorage(FloatingLyricsMode.key) private var mode: FloatingLyricsMode = .always
    @AppStorage(FloatingLyricsMode.whenTuckedKey) private var showWhenTucked = false
    @AppStorage(FloatingBall.twoLinesKey) private var twoLines = false

    var body: some View {
        let ball = FloatingBall.shared
        let s = ball.lyricScale
        // 调胶囊大小时没歌词也显示一条示例
        let preview = ball.adjustingLyric && currentLine.isEmpty
        let line = preview ? "歌词胶囊大小预览" : currentLine
        let next = preview ? "下一句歌词" : nextLine
        let visible = ball.adjustingLyric || (!line.isEmpty && player.playedThisLaunch && (ball.tuckedEdge == nil || showWhenTucked)
            && mode != .off && (mode == .always || ball.hovering))
        // 文字靠球那一边对齐
        let align: HorizontalAlignment = ball.lyricOnLeft ? .trailing : .leading
        let rowAlign: Alignment = ball.lyricOnLeft ? .trailing : .leading
        // 量大小用：现在这句（+ 下一句），不显示，只撑开胶囊。宽度跟着这几句变，带动画
        VStack(alignment: align, spacing: 2 * s) {
            Text(line).font(.ui(14 * s, .semibold)).lineLimit(1)
            if twoLines && !next.isEmpty {
                Text(next).font(.ui(11 * s, .medium)).lineLimit(1)
            }
        }
        .opacity(0)
        // 真正显示的：前后几句排成一列，换句时整列往上推一行；
        // 下一句一边上移一边放大变亮成为当前这句，旧的当前句往上移出、变淡
        .overlay(alignment: rowAlign) {
            if preview {
                VStack(alignment: align, spacing: 2 * s) {
                    Text(line).font(.ui(14 * s, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if twoLines { Text(next).font(.ui(11 * s, .medium)).foregroundStyle(Theme.text2).lineLimit(1) }
                }
            } else {
                scrollingRows(scale: s, align: rowAlign)
            }
        }
        .padding(.horizontal, 16 * s)
        .padding(.vertical, twoLines ? 8 * s : 0)
        .frame(minHeight: (36 * s).rounded())
        .clipped()
        .background {
            ZStack {
                GlassBackground(cornerRadius: 18 * s)
                RoundedRectangle(cornerRadius: 18 * s, style: .continuous).fill(Theme.card.opacity(0.35))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18 * s, style: .continuous))
        // 双击胶囊回主窗口
        .contentShape(RoundedRectangle(cornerRadius: 18 * s, style: .continuous))
        .onTapGesture(count: 2) { FloatingBall.shared.exit() }
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: 0.35), value: player.currentLyricIndex)
        // 贴着球那一边对齐，长度跟着歌词变，最长到整个歌词条；上下居中对齐球
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: ball.lyricOnLeft ? .trailing : .leading)
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: visible)
        // 胶囊不显示时整条歌词窗口都不接鼠标，不挡后面的东西
        .onChange(of: visible, initial: true) { _, shown in FloatingBall.shared.setLyricClickable(shown) }
    }

    /// 有字的歌词行（跳过空行），按顺序
    private var textRows: [(index: Int, text: String)] {
        guard player.lyricsState == .loaded else { return [] }
        return player.lyrics.enumerated().compactMap { i, l in
            let t = l.text.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : (i, t)
        }
    }

    /// 当前句前后几行，每行按「离当前句差几行」往上 / 往下摆。换句时每行的位置一起动起来，看起来就是整列往上推
    private func scrollingRows(scale s: CGFloat, align: Alignment) -> some View {
        let rows = textRows
        let current = player.currentLyricIndex ?? -1
        // 当前句在 rows 里的位置（当前是空行时取它前面最近的一句）
        let pos = rows.lastIndex { $0.index <= current } ?? -1
        let pitch = (twoLines ? 19 : 26) * s
        // 两行时当前句在上半、下一句在下半；一行时当前句在正中
        let base = twoLines ? -pitch / 2 : 0
        let window = rows.indices.filter { $0 >= pos - 1 && $0 <= pos + 2 }
        let small = 11.0 / 14.0
        return GeometryReader { geo in
            ZStack(alignment: align) {
                ForEach(window, id: \.self) { k in
                    let isCurrent = k == pos
                    let shown = isCurrent || (twoLines && k == pos + 1)
                    Text(rows[k].text)
                        .font(.ui(14 * s, .semibold))
                        .foregroundStyle(isCurrent ? Theme.text : Theme.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // 字号换不出平滑动画，用缩放：不是当前句时缩到 11/14，靠球那一边对齐；
                        // 排版时按缩放前的宽度给，缩完正好是胶囊的宽度，不会提前出省略号
                        .frame(width: geo.size.width / (isCurrent ? 1 : small), alignment: align)
                        .scaleEffect(isCurrent ? 1 : small, anchor: align == .trailing ? .trailing : .leading)
                        .frame(width: geo.size.width, alignment: align)
                        .opacity(shown ? 1 : 0)
                        .offset(y: base + CGFloat(k - pos) * pitch)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: align)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
    }

    /// 当前这一句；没有逐句歌词时为空（不显示歌词条）
    private var currentLine: String {
        guard player.lyricsState == .loaded, let i = player.currentLyricIndex, player.lyrics.indices.contains(i) else { return "" }
        return player.lyrics[i].text.trimmingCharacters(in: .whitespaces)
    }

    /// 下一句（跳过空行）
    private var nextLine: String {
        guard player.lyricsState == .loaded else { return "" }
        let start = (player.currentLyricIndex ?? -1) + 1
        guard start < player.lyrics.count else { return "" }
        return player.lyrics[start...].lazy.map { $0.text.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
}


/// 「悬浮球大小」卡片：粗胶囊滑条 + 赭橙进度，滑块一动，悬浮球和歌词条马上跟着变
private struct FloatingBallSizeView: View {
    let title: String
    let range: ClosedRange<CGFloat>
    let defaultValue: CGFloat
    let label: (CGFloat) -> String
    let apply: (CGFloat) -> Void
    let done: () -> Void
    @State private var value: CGFloat

    init(title: String, range: ClosedRange<CGFloat>, defaultValue: CGFloat, initial: CGFloat,
         label: @escaping (CGFloat) -> String, apply: @escaping (CGFloat) -> Void, done: @escaping () -> Void) {
        self.title = title
        self.range = range
        self.defaultValue = defaultValue
        self.label = label
        self.apply = apply
        self.done = done
        _value = State(initialValue: initial)
    }

    private let knob: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.ui(14, .bold)).foregroundStyle(Theme.text)
                Spacer()
                ChipText(text: label(value), color: Theme.surface, foreground: Theme.text, font: .ui(12, .bold).monospacedDigit())
            }
            HStack(spacing: 10) {
                Image(systemName: "circle").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text2)
                slider
                Image(systemName: "circle").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text2)
            }
            HStack {
                Button { set(defaultValue) } label: {
                    ChipText(text: "恢复默认", color: Theme.surface, foreground: Theme.text, font: .ui(12, .semibold),
                             hPad: 14, vPad: 6)
                }
                .buttonStyle(.plain)
                .disabled(value == defaultValue)
                .opacity(value == defaultValue ? 0.45 : 1)
                Spacer()
                Button(action: done) {
                    ChipText(text: "完成", color: Theme.accent, foreground: Theme.ink, font: .ui(12, .bold), hPad: 18, vPad: 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.line, lineWidth: 1)
        }
        .foregroundStyle(Theme.text)
    }

    private var slider: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                CapsuleBar(value: t, height: 6)
                Circle()
                    .fill(Theme.text)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: t * (width - knob))
            }
            .frame(height: knob)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let p = min(1, max(0, (drag.location.x - knob / 2) / (width - knob)))
                set(range.lowerBound + p * (range.upperBound - range.lowerBound))
            })
        }
        .frame(height: knob)
    }

    private func set(_ new: CGFloat) {
        // 悬浮球按整数像素，歌词胶囊按 5% 一档
        value = range.upperBound > 10 ? new.rounded() : (new * 20).rounded() / 20
        apply(value)
    }
}

/// 调大小卡片不抢焦点，第一次点就响应
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 带闭包的菜单项
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { MainActor.assumeIsolated { handler() } }
}
