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
    static let sizeRange: ClosedRange<CGFloat> = 40...160
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

    /// 「贴边颜色」：贴边半圆球上的进度环、圆点、音柱用什么颜色。
    /// auto 按球后面的深浅自动选；有些壁纸读不到（比如「照片」App 设的壁纸），自动会选错，就手动定成白色或黑色
    static let tuckColorKey = "floatingBallTuckColor"
    static var tuckColor: String { UserDefaults.standard.string(forKey: tuckColorKey) ?? "auto" }

    func setTuckColor(_ value: String) {
        UserDefaults.standard.set(value, forKey: Self.tuckColorKey)
        if let frame = panel?.frame { updateBackdrop(for: frame) }
    }

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
    private(set) var lyricScale: CGFloat = FloatingBall.lyricBase(FloatingBall.size) * FloatingBall.lyricSize
    /// 歌词胶囊跟着球一起变大变小；球调得很小（小于 64，多半是为了贴上边时不超出菜单栏）时歌词不再跟着变小，免得看不清
    static func lyricBase(_ size: CGFloat) -> CGFloat { max(size, 64) / defaultSize }
    private static let originKey = "floatingBallOrigin"

    /// 鼠标是否在球上（用 AppKit 的跟踪区域检测，Groove 不在前台时也有效）
    var hovering = false

    @ObservationIgnored private var panel: NSPanel?
    /// 旁边的歌词条（单独的小窗口，挂在球的窗口上，跟着球一起动；不接收鼠标，不挡拖动）
    @ObservationIgnored private var lyricPanel: NSPanel?
    /// 歌词条往左伸（球在屏幕右半边时）还是往右伸
    private(set) var lyricOnLeft = true
    /// 贴在上 / 下边时歌词条放在球的下面 / 上面，文字居中
    private(set) var lyricCentered = false
    /// 贴在上边时歌词放进菜单栏里（球旁边）：只显示一行，没有胶囊底，只有字
    private(set) var lyricInMenuBar = false

    /// 「歌词胶囊跟随封面颜色」（默认开）：球旁边、上下边、刘海下面的歌词胶囊染成当前封面的颜色；
    /// 关掉就是原来的样子（球旁边是玻璃底，刘海下面按后面的深浅换深色 / 浅色）。菜单栏里那行字不受影响
    static let lyricCoverTintKey = "floatingLyricCoverTint"
    static var lyricCoverTint: Bool { UserDefaults.standard.object(forKey: lyricCoverTintKey) as? Bool ?? true }
    /// 当前这首歌封面的主色；没有封面时为 nil
    private(set) var lyricTint: Color?
    @ObservationIgnored private var lyricTintPath: String?

    /// 换歌时重新取一次封面颜色（同一首不重复算）
    func updateLyricTint(for track: Track?) async {
        guard let track else {
            lyricTintPath = nil
            withAnimation(.easeInOut(duration: 0.5)) { lyricTint = nil }
            return
        }
        guard track.path != lyricTintPath else { return }
        lyricTintPath = track.path
        let cover = await ArtworkProvider.shared.coverColor(for: track)
        guard lyricTintPath == track.path else { return }
        withAnimation(.easeInOut(duration: 0.5)) { lyricTint = cover.map { Color(nsColor: $0) } }
    }

    func setLyricCoverTint(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.lyricCoverTintKey)
    }
    @ObservationIgnored private weak var mainWindow: NSWindow?

    /// 球露着，或者吸附在刘海上（这时球藏起来，只显示刘海下面的歌词）
    var isShown: Bool { (panel?.isVisible ?? false) || (islandPanel?.isVisible ?? false) }

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
            if target != frame { panel.setFrame(target, display: true) }
            updateDock(for: target)
            positionLyricPanel(for: target)
            if !hovering { scheduleTuck(after: 0.8) }
        } else {
            // 不贴边了：菜单栏里的歌词马上回到球旁边的胶囊里
            positionLyricPanel(for: frame)
        }
    }

    /// 只放出悬浮球（不动主窗口）
    func show(player: PlayerController) {
        guard !isShown else { return }
        let panel = self.panel ?? makePanel(player: player)
        self.panel = panel
        panel.setFrameOrigin(savedOrigin())
        tucked = false
        tuckedEdge = nil   // 一出来是完整的球（转动的封面），等藏进去时才换成半圆的样子
        ballSize = Self.size
        scale = Self.size / Self.defaultSize
        lyricScale = Self.lyricBase(Self.size) * Self.lyricSize
        panel.setContentSize(NSSize(width: Self.size, height: Self.size))
        installMouseMonitor()
        watchBackdropEvents()
        // 上次是吸附在刘海上收起来的：直接回到刘海上
        if UserDefaults.standard.bool(forKey: Self.islandKey), let screen = Self.notchScreen() {
            enterIsland(on: screen, animated: false)
            return
        }
        panel.hasShadow = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        updateDock(for: panel.frame)
        attachLyricPanel(player: player)
        scheduleTuck(after: 1.5)
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
        guard let panel, isShown else { return }
        backdropTimer?.invalidate()
        backdropTimer = nil
        closeQueue()
        cancelTuck()
        removeMouseMonitor()
        // 吸附在刘海上时球的位置不算数，留着上次的；「吸附在刘海上」也记着，下次出来还在刘海上
        if inIsland {
            inIsland = false
            islandTimer?.invalidate()
            islandTimer = nil
            islandExpanded = false
            islandPanel?.orderOut(nil)
        } else {
            UserDefaults.standard.set(NSStringFromPoint((tucked ? shownFrame : nil)?.origin ?? panel.frame.origin),
                                      forKey: Self.originKey)
        }
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
        // 贴上边时歌词在菜单栏里、没挂在球上：拖起来时挪回球旁边、重新挂上
        if lyricInMenuBar { positionLyricPanel(for: panel.frame) }
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
        // 拖到刘海附近松手：吸到刘海上
        if let screen = islandScreen(near: panel.frame) {
            enterIsland(on: screen, animated: true)
            return
        }
        let target = snapped(panel.frame, on: panel.screen ?? NSScreen.main)
        // 先定下贴在哪条边，歌词条才知道放在旁边还是上下
        updateDock(for: target)
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
        if !hovering { scheduleTuck(after: 0.8) }
    }

    // MARK: 贴边藏一半（像 QQ 音乐）：贴在左右边时，鼠标离开一会儿就滑出去一半，移上去再滑回来

    enum DockEdge { case left, right, top, bottom }

    @ObservationIgnored private var dock: DockEdge?
    /// 贴边时完整露出来的位置
    @ObservationIgnored private var shownFrame: NSRect?
    @ObservationIgnored private var tucked = false
    /// 藏起一半时贴在哪边（界面据此改成「半圆进度 + 播放状态」），露出来时为 nil
    private(set) var tuckedEdge: DockEdge?
    /// 藏起一半时球后面是不是浅色的（浅色 → 进度环、音柱用黑色；深色 → 白色）
    private(set) var backdropIsLight = false
    @ObservationIgnored private var backdropTimer: Timer?
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

    /// 贴在左 / 右 / 上 / 下边、而且那一侧没有别的显示器时，才算「贴边」（贴在角上时算左右边）。
    /// 有刘海的屏幕上，正对着刘海的那段上边不算（那里是吸到刘海上）
    private func updateDock(for frame: NSRect) {
        defer {
            // 不再贴在上边了（关掉自动贴边、改大小、换屏幕……）：菜单栏里的歌词马上回到球旁边的胶囊里
            if lyricInMenuBar, dock != .top { positionLyricPanel(for: frame) }
        }
        dock = nil
        shownFrame = frame
        guard let screen = panel?.screen ?? NSScreen.main else { return }
        let lo = screen.visibleFrame.insetBy(dx: Self.edgeGap, dy: Self.edgeGap)
        guard Self.autoDock else { return }
        let mid = frame.midY
        func neighbor(atX x: CGFloat) -> Bool {
            NSScreen.screens.contains { $0 != screen && $0.frame.contains(NSPoint(x: x, y: mid)) }
        }
        func neighbor(atY y: CGFloat) -> Bool {
            NSScreen.screens.contains { $0 != screen && $0.frame.contains(NSPoint(x: frame.midX, y: y)) }
        }
        let underNotch = Self.notchRect(of: screen).map { frame.maxX > $0.minX && frame.minX < $0.maxX } ?? false
        if abs(frame.minX - lo.minX) < 1, !neighbor(atX: screen.frame.minX - 2) {
            dock = .left
        } else if abs(frame.maxX - lo.maxX) < 1, !neighbor(atX: screen.frame.maxX + 2) {
            dock = .right
        } else if abs(frame.maxY - lo.maxY) < 1, !underNotch, !neighbor(atY: screen.frame.maxY + 2) {
            dock = .top
        } else if abs(frame.minY - lo.minY) < 1, !neighbor(atY: screen.frame.minY - 2) {
            dock = .bottom
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

    /// 滑出去一半，只露半个球（贴左右边时上下位置不变，贴上下边时左右位置不变）。
    /// 上边藏进屏幕最上沿（露出来的半个球压在菜单栏上）；下边程序坞常驻在下面时停在程序坞上沿，不然藏进屏幕最下沿
    private func tuck() {
        guard let dock, let shown = shownFrame, let screen = panel?.screen ?? NSScreen.main else { return }
        let edge = screen.visibleFrame
        let side = Self.tuckedSize
        let frame: NSRect
        switch dock {
        case .left, .right:
            frame = NSRect(x: dock == .left ? edge.minX - side / 2 : edge.maxX - side / 2,
                           y: shown.midY - side / 2, width: side, height: side)
        case .top:
            frame = NSRect(x: shown.midX - side / 2, y: screen.frame.maxY - side / 2, width: side, height: side)
        case .bottom:
            let dockShown = edge.minY - screen.frame.minY > 10
            let bottom = dockShown ? edge.minY : screen.frame.minY
            frame = NSRect(x: shown.midX - side / 2, y: bottom - side / 2, width: side, height: side)
        }
        slide(to: frame, tucked: true)
    }

    private func slide(to frame: NSRect?, tucked: Bool) {
        guard let panel, let frame else { return }
        self.tucked = tucked
        // 藏起来时马上看一眼球后面；之后切换 App、换桌面等时候再看（见 watchBackdropEvents），
        // 另外每 3 秒补看一次（别的窗口挪过来盖住之类没有通知的情况）。露出来就不用看了
        backdropTimer?.invalidate()
        backdropTimer = nil
        if tucked {
            updateBackdrop(for: frame)
            backdropTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard ScreenColorSampler.screenAvailable else { return }
                    let ball = FloatingBall.shared
                    if let frame = ball.panel?.frame { ball.updateBackdrop(for: frame) }
                }
            }
            backdropTimer?.tolerance = 1
        }
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
            // 歌词条跟着球一起挪过了，滑完以后再按球现在的位置对齐一次（贴边时也可能显示歌词条）；
            // 藏好以后再看一眼球后面（滑动前看的那一眼可能被别的东西挡着）
            MainActor.assumeIsolated {
                FloatingBall.shared.positionLyricPanel(for: frame)
                if tucked { FloatingBall.shared.scheduleBackdropCheck() }
            }
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
        lyricScale = Self.lyricBase(size) * Self.lyricSize
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
        lyricScale = Self.lyricBase(scale * Self.defaultSize) * v
        if let panel { positionLyricPanel(for: tucked ? (shownFrame ?? panel.frame) : panel.frame) }
        positionIsland()
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
        if inIsland {
            menu.addItem(item("变回悬浮球") { FloatingBall.shared.leaveIsland() })
        } else if let screen = Self.notchScreen() {
            menu.addItem(item("吸附到刘海") { FloatingBall.shared.enterIsland(on: screen, animated: true) })
        }
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
        menu.addItem(item("歌词胶囊跟随封面颜色", checked: Self.lyricCoverTint, enabled: mode != .off) {
            FloatingBall.shared.setLyricCoverTint(!FloatingBall.lyricCoverTint)
        })
        menu.addItem(item("显示两行歌词", checked: Self.twoLines, enabled: mode != .off) {
            FloatingBall.shared.setTwoLines(!FloatingBall.twoLines)
        })
        let whenTucked = UserDefaults.standard.bool(forKey: FloatingLyricsMode.whenTuckedKey)
        menu.addItem(item("贴边时也显示歌词", checked: whenTucked, enabled: mode != .off) {
            UserDefaults.standard.set(!whenTucked, forKey: FloatingLyricsMode.whenTuckedKey)
        })
        let hideWhenPaused = UserDefaults.standard.bool(forKey: FloatingLyricsMode.hideWhenPausedKey)
        menu.addItem(item("暂停时不显示歌词", checked: hideWhenPaused, enabled: mode != .off) {
            UserDefaults.standard.set(!hideWhenPaused, forKey: FloatingLyricsMode.hideWhenPausedKey)
        })
        menu.addItem(item("始终置顶", checked: Self.onTop) {
            FloatingBall.shared.setOnTop(!FloatingBall.onTop)
        })
        menu.addItem(item("自动贴边", checked: Self.autoDock) {
            FloatingBall.shared.setAutoDock(!FloatingBall.autoDock)
        })
        let colorItem = NSMenuItem(title: "贴边颜色", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for (value, label) in [("auto", "自动"), ("white", "白色（深色壁纸用）"), ("black", "黑色（浅色壁纸用）")] {
            colorMenu.addItem(item(label, checked: Self.tuckColor == value) { FloatingBall.shared.setTuckColor(value) })
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)
        menu.addItem(item("读取屏幕颜色（需要屏幕录制权限）",
                          checked: ScreenColorSampler.enabled && ScreenColorSampler.granted) {
            ScreenColorSampler.toggle()
        })
        menu.addItem(item("一直显示悬浮球", checked: Self.alwaysOn) {
            FloatingBall.shared.setAlwaysOn(!FloatingBall.alwaysOn, player: player)
        })
        menu.addItem(.separator())
        menu.addItem(item("关闭悬浮球") { FloatingBall.shared.close() })
        return menu
    }

    // MARK: 球后面是深色还是浅色

    /// 看球后面是什么：Groove 自己的主窗口在后面就按它的底色（深色 / 浅色外观）；
    /// 不然看桌面壁纸上球所在那一小块的亮度。别的 App 的窗口看不到（那要「屏幕录制」权限），只能按壁纸算。
    /// 开了「读取屏幕颜色」并且有权限时，直接截球后面那一小块看亮度，截不到再按上面的办法猜
    func updateBackdrop(for frame: NSRect) {
        // 「自动」时最准的是截后面的颜色，要屏幕录制权限：第一次贴边藏起来时向系统要一次（只弹这一次，Groove 也会出现在设置的列表里）
        if Self.tuckColor == "auto", ScreenColorSampler.enabled, !ScreenColorSampler.granted,
           !UserDefaults.standard.bool(forKey: ScreenColorSampler.askedKey) {
            UserDefaults.standard.set(true, forKey: ScreenColorSampler.askedKey)
            CGRequestScreenCaptureAccess()
        }
        if Self.tuckColor == "auto", ScreenColorSampler.enabled, ScreenColorSampler.granted {
            guard !ballSampling else { return }
            ballSampling = true
            Task {
                let lum = await ScreenColorSampler.luminance(of: frame, excluding: self.ownWindowNumbers)
                self.ballSampling = false
                if let lum { self.setBackdropLight(lum > 0.55) } else { self.guessBackdrop(for: frame) }
            }
            return
        }
        guessBackdrop(for: frame)
    }

    @ObservationIgnored private var ballSampling = false
    @ObservationIgnored private var islandSampling = false

    // MARK: 什么时候看后面的颜色：位置变了、切换 App、换桌面、屏幕变化、睡醒时马上看（合并成一次），平时 3 秒补看一次

    @ObservationIgnored private var backdropCheck: DispatchWorkItem?
    @ObservationIgnored private var backdropObservers: [Any] = []

    /// 过一小会儿看一次后面的颜色；这段时间里又有变化就只看最后那一次，不重复截
    func scheduleBackdropCheck(after delay: Double = 0.18) {
        backdropCheck?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let ball = FloatingBall.shared
                guard ScreenColorSampler.screenAvailable else { return }
                if ball.inIsland {
                    ball.updateIslandBackdrop()
                } else if ball.tucked, let frame = ball.panel?.frame {
                    ball.updateBackdrop(for: frame)
                }
            }
        }
        backdropCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func watchBackdropEvents() {
        guard backdropObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let handler: (Notification) -> Void = { _ in
            MainActor.assumeIsolated { FloatingBall.shared.scheduleBackdropCheck(after: 0.3) }
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            backdropObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main, using: handler))
        }
        backdropObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                        object: nil, queue: .main, using: handler))
        // 接上 / 拔掉显示器、改分辨率：重新摆一次球（见 screensChanged）
        backdropObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                        object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FloatingBall.shared.scheduleScreensChanged() }
        })
    }

    @ObservationIgnored private var screensChangedWork: DispatchWorkItem?

    /// 显示器变化时通知会连着来好几次，等安静 0.5 秒再处理一次
    private func scheduleScreensChanged() {
        screensChangedWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { FloatingBall.shared.screensChanged() }
        }
        screensChangedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 接上 / 拔掉显示器以后，系统可能把球挪到别处，原来贴的那条边也可能没了（旁边接了显示器），
    /// 这时还按藏起一半的样子显示就会出现「屏幕中间半个球」。所以先变回完整的球，放回屏幕里，
    /// 再按新的屏幕重新判断贴哪条边（开着自动贴边时贴过去，过一会儿再藏起来）。吸在刘海上时由刘海那边处理
    func screensChanged() {
        guard let panel, panel.isVisible, !inIsland, dragStart == nil else { return }
        cancelTuck()
        let full = Self.size
        let old = tucked ? (shownFrame ?? panel.frame) : panel.frame
        var frame = NSRect(x: old.midX - full / 2, y: old.midY - full / 2, width: full, height: full)
        // 还在某块屏幕上就放在那块，不然放到主屏幕上
        let screen = NSScreen.screens.max { a, b in
            let ia = a.visibleFrame.intersection(frame), ib = b.visibleFrame.intersection(frame)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }.flatMap { $0.visibleFrame.intersects(frame) ? $0 : nil } ?? NSScreen.main
        frame = snapped(frame, on: screen)
        tucked = false
        backdropTimer?.invalidate()
        backdropTimer = nil
        panel.hasShadow = true
        panel.setFrame(frame, display: true)
        withAnimation(.easeInOut(duration: 0.2)) {
            tuckedEdge = nil
            ballSize = full
        }
        updateDock(for: frame)
        positionLyricPanel(for: frame)
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
        if !hovering { scheduleTuck(after: 0.8) }
    }

    /// Groove 自己的悬浮窗（截屏幕颜色时不算它们）
    private var ownWindowNumbers: [Int] {
        [panel, lyricPanel, islandPanel, queuePanel, sizePanel].compactMap { $0?.windowNumber }
    }

    private func setBackdropLight(_ light: Bool) {
        if light != backdropIsLight {
            withAnimation(.easeInOut(duration: 0.3)) { backdropIsLight = light }
        }
    }

    private func guessBackdrop(for frame: NSRect) {
        let light: Bool
        if Self.tuckColor != "auto" {
            // 手动定了颜色：白色是给深色背景用的
            light = Self.tuckColor == "black"
        } else {
            light = guessLight(behind: frame)
        }
        setBackdropLight(light)
    }

    /// 不截屏时猜某块屏幕后面是深是浅：最前面盖住这块的是 Groove 自己的窗口就按它的外观；
    /// 是别的 App 的窗口就按系统的深色 / 浅色外观（窗口里具体画了什么要「屏幕录制」权限才看得到，这里只用窗口的位置）；
    /// 没有窗口就看桌面壁纸那一块的亮度；壁纸也读不到（比如「照片」App 设的壁纸）就按系统外观
    private func guessLight(behind area: NSRect) -> Bool {
        let systemLight = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") != "Dark"
        // 窗口列表用的坐标原点在主屏幕左上角，往下是正
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let cgArea = CGRect(x: area.minX, y: primaryHeight - area.maxY, width: area.width, height: area.height)
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        let own = Set(ownWindowNumbers)
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let number = info[kCGWindowNumber as String] as? Int, !own.contains(number),
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.intersects(cgArea) else { continue }
            if (info[kCGWindowOwnerPID as String] as? Int32) == me,
               let main = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible && $0.canBecomeMain && !$0.isMiniaturized }) {
                return main.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .darkAqua
            }
            return systemLight
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: area.midX, y: area.midY)) }) ?? panel?.screen,
           let lum = Self.wallpaperBrightness(behind: area, on: screen) {
            return lum > 0.55
        }
        return systemLight
    }

    /// 缩小的壁纸（按文件缓存），算亮度用；image 为 nil 表示这张读不了或不该读，换壁纸 / 改开关前不再试
    @ObservationIgnored private static var wallpaperCache: (url: URL, image: CGImage?)?

    /// 系统自带壁纸放的地方，读它们不用权限
    private static let systemWallpaperDirs = ["/System/Library/Desktop Pictures/", "/Library/Desktop Pictures/"]

    private static func wallpaperBrightness(behind frame: NSRect, on screen: NSScreen) -> Double? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let image: CGImage
        if let cached = wallpaperCache, cached.url == url {
            guard let cachedImage = cached.image else { return nil }
            image = cachedImage
        } else {
            let path = url.standardizedFileURL.path
            // 只读系统自带壁纸（不用权限）；自己的图片放在桌面、文稿等文件夹里一读 macOS 就会弹权限框，所以不读
            let allowed = systemWallpaperDirs.contains { path.hasPrefix($0) }
            guard allowed, let data = try? Data(contentsOf: url), let small = ArtworkProvider.downsample(data, maxPixel: 256) else {
                wallpaperCache = (url, nil)
                return nil
            }
            wallpaperCache = (url, small)
            image = small
        }
        // 壁纸默认「填充屏幕」：按比例放大铺满，多出来的两边（或上下）裁掉
        let sf = screen.frame
        let iw = Double(image.width), ih = Double(image.height)
        let scale = max(sf.width / iw, sf.height / ih)
        let offX = (iw * scale - sf.width) / 2, offY = (ih * scale - sf.height) / 2
        let r = frame.intersection(sf)
        guard !r.isNull, r.width > 0 else { return nil }
        // 屏幕坐标（左下为原点）→ 图片像素（左上为原点）
        let x0 = (r.minX - sf.minX + offX) / scale, x1 = (r.maxX - sf.minX + offX) / scale
        let y0 = (sf.maxY - r.maxY + offY) / scale, y1 = (sf.maxY - r.minY + offY) / scale
        let crop = CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0)).integral
        guard let piece = image.cropping(to: crop) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(piece, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / 255
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

    // MARK: 吸附到刘海（像灵动岛）
    // 球拖到刘海附近松手就吸上去：球藏起来，刘海下面隔一小段悬着一个歌词胶囊（和球旁边的歌词胶囊一个样子）。
    // 往下拖这块胶囊就变回悬浮球；双击回主窗口；右键和球的菜单一样。没有刘海的屏幕不会吸附。

    /// 记着是不是吸附在刘海上（下次打开悬浮球还在刘海上）
    static let islandKey = "floatingBallIsland"
    /// 吸附在刘海上
    private(set) var inIsland = false
    /// 刘海下面的歌词胶囊出来了（刚吸上去时从刘海里弹出来，离开时缩回去）
    private(set) var islandExpanded = false
    /// 刘海的大小（胶囊放在它下面，至少和它一样宽）
    private(set) var islandNotchSize = CGSize(width: 200, height: 32)
    /// 刘海下面那块背后是不是浅色的（浅色 → 胶囊用深色毛玻璃；深色 → 浅色毛玻璃，两种都看得清）
    private(set) var islandBackdropLight = false
    @ObservationIgnored private var islandTimer: Timer?
    @ObservationIgnored private var islandPanel: NSPanel?
    @ObservationIgnored private var islandNotch: NSRect?
    @ObservationIgnored private var screenObserver: Any?

    /// 胶囊和刘海下沿之间空出来的距离
    static let islandGap: CGFloat = 7
    /// 歌词最宽到这么宽（再长就省略号）
    var islandMaxWidth: CGFloat { max(islandNotchSize.width, 420 * lyricScale) }
    /// 刘海下面放歌词的高度
    var islandContentHeight: CGFloat { lyricHeight }

    /// 屏幕上刘海的位置（全局坐标）；没有刘海返回 nil
    static func notchRect(of screen: NSScreen) -> NSRect? {
        let top = screen.safeAreaInsets.top
        guard top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let width = screen.frame.width - left.width - right.width
        guard width > 0 else { return nil }
        return NSRect(x: screen.frame.minX + left.width, y: screen.frame.maxY - top, width: width, height: top)
    }

    /// 有刘海的屏幕（一般就是 MacBook 自带的屏幕）
    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { notchRect(of: $0) != nil }
    }

    /// 球松手的位置离哪块屏幕的刘海够近（开着「自动贴边」才吸）
    private func islandScreen(near frame: NSRect) -> NSScreen? {
        guard Self.autoDock else { return nil }
        return NSScreen.screens.first { screen in
            guard let notch = Self.notchRect(of: screen) else { return false }
            return notch.minY - frame.maxY < Self.snapDistance
                && abs(frame.midX - notch.midX) < (notch.width + frame.width) / 2
        }
    }

    /// 吸到刘海上：球缩成一个点飞进刘海、淡掉，刘海往下弹出歌词
    func enterIsland(on screen: NSScreen, animated: Bool) {
        guard let panel, let notch = Self.notchRect(of: screen) else { return }
        cancelTuck()
        closeQueue()
        dock = nil
        tucked = false
        tuckedEdge = nil
        hovering = false
        backdropTimer?.invalidate()
        backdropTimer = nil
        islandNotch = notch
        islandNotchSize = notch.size
        inIsland = true
        UserDefaults.standard.set(true, forKey: Self.islandKey)
        if let lyricPanel {
            panel.removeChildWindow(lyricPanel)
            lyricPanel.orderOut(nil)
        }
        let island = islandPanel ?? makeIslandPanel()
        islandPanel = island
        islandExpanded = false
        positionIsland()
        island.orderFrontRegardless()
        startIslandBackdropWatch()
        if animated && panel.isVisible {
            let dot = NSRect(x: notch.midX - 8, y: notch.midY - 8, width: 16, height: 16)
            panel.hasShadow = false
            withAnimation(.easeIn(duration: 0.22)) { ballSize = 16 }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(dot, display: true)
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    let ball = FloatingBall.shared
                    guard ball.inIsland else { return }
                    ball.panel?.orderOut(nil)
                    ball.panel?.alphaValue = 1
                }
            }
        } else {
            panel.orderOut(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.12 : 0.05)) {
            guard self.inIsland else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) { self.islandExpanded = true }
        }
    }

    /// 离开刘海变回悬浮球。从刘海上往下拖时，球出现在鼠标下面、接着跟着鼠标拖；
    /// 菜单里点「变回悬浮球」时回到上次球的位置
    func leaveIsland(dragFrom mouse: NSPoint? = nil) {
        guard inIsland, let panel, let player = menuPlayer else { return }
        inIsland = false
        islandTimer?.invalidate()
        islandTimer = nil
        UserDefaults.standard.set(false, forKey: Self.islandKey)
        withAnimation(.easeInOut(duration: 0.2)) { islandExpanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if !self.inIsland { self.islandPanel?.orderOut(nil) }
        }
        let size = Self.size
        ballSize = size
        tucked = false
        tuckedEdge = nil
        let origin = mouse.map { NSPoint(x: $0.x - size / 2, y: $0.y - size / 2) } ?? savedOrigin()
        panel.setFrame(NSRect(origin: origin, size: CGSize(width: size, height: size)), display: true)
        panel.alphaValue = 1
        panel.hasShadow = true
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        if mouse == nil { updateDock(for: panel.frame) }
        attachLyricPanel(player: player)
        if let mouse {
            dragStart = (mouse, panel.frame.origin)
        } else {
            scheduleTuck(after: 1.5)
        }
    }

    /// 吸上去时马上看一眼胶囊后面是深色还是浅色，切换 App、换桌面时再看，另外每 3 秒补看一次
    private func startIslandBackdropWatch() {
        islandTimer?.invalidate()
        updateIslandBackdrop()
        islandTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard ScreenColorSampler.screenAvailable else { return }
                FloatingBall.shared.updateIslandBackdrop()
            }
        }
        islandTimer?.tolerance = 1
    }

    /// 胶囊后面是什么：最前面盖住这块的是 Groove 自己的窗口就按它的外观；是别的 App 的窗口就按系统的深色 / 浅色外观
    /// （窗口里具体画了什么要「屏幕录制」权限才看得到，这里只用窗口的位置）；没有窗口就看桌面壁纸那一块的亮度
    /// 开了「读取屏幕颜色」并且有权限时，直接截胶囊后面那块看亮度（不带胶囊自己），截不到再按上面的办法猜
    private func updateIslandBackdrop() {
        guard inIsland, let notch = islandNotch else { return }
        let area = NSRect(x: notch.minX, y: notch.minY - Self.islandGap - islandContentHeight,
                          width: notch.width, height: islandContentHeight)
        if ScreenColorSampler.enabled, ScreenColorSampler.granted {
            guard !islandSampling else { return }
            islandSampling = true
            Task {
                let lum = await ScreenColorSampler.luminance(of: area, excluding: self.ownWindowNumbers)
                self.islandSampling = false
                guard self.inIsland else { return }
                if let lum { self.setIslandBackdropLight(lum > 0.55) } else { self.guessIslandBackdrop(area: area, notch: notch) }
            }
            return
        }
        guessIslandBackdrop(area: area, notch: notch)
    }

    private func setIslandBackdropLight(_ light: Bool) {
        if light != islandBackdropLight {
            withAnimation(.easeInOut(duration: 0.3)) { islandBackdropLight = light }
        }
    }

    private func guessIslandBackdrop(area: NSRect, notch: NSRect) {
        setIslandBackdropLight(guessLight(behind: area))
    }

    /// 从刘海上拖下来以后，鼠标还按在刘海的窗口上，移动交给这里让球跟着走
    fileprivate func islandDragMoved(to mouse: NSPoint) {
        moveWithMouse(mouse)
    }

    /// 刘海窗口：宽度按最长的歌词留够，高度 = 刘海 + 空隙 + 胶囊；顶边贴着屏幕最上面，左右以刘海为中心。
    /// 只有胶囊那块不透明，其余透明，点击会穿过去
    private func positionIsland() {
        guard let islandPanel, let notch = islandNotch else { return }
        let width = islandMaxWidth + 24
        let height = notch.height + Self.islandGap + islandContentHeight + 16
        islandPanel.setFrame(NSRect(x: notch.midX - width / 2, y: notch.maxY - height, width: width, height: height),
                             display: true)
    }

    private func makeIslandPanel() -> NSPanel {
        let panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // 要盖在菜单栏上面
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        if let player = menuPlayer {
            let host = IslandHostingView(rootView: NotchIslandView().environment(player).modifier(ThemedAppearance()))
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
        }
        // 接上 / 拔掉显示器、合上盖子：刘海那块屏幕没了就变回悬浮球，还在就重新对齐
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let ball = FloatingBall.shared
                guard ball.inIsland else { return }
                if let screen = FloatingBall.notchScreen(), let notch = FloatingBall.notchRect(of: screen) {
                    ball.islandNotch = notch
                    ball.islandNotchSize = notch.size
                    ball.positionIsland()
                } else {
                    ball.leaveIsland()
                }
            }
        }
        return panel
    }

    // MARK: 歌词条

    var lyricWidth: CGFloat { 320 * lyricScale }
    var lyricHeight: CGFloat { ((Self.twoLines && !lyricInMenuBar ? 58 : 36) * lyricScale).rounded() }

    /// 「显示两行歌词」：当前这句 + 下一句（小一点、淡一点）
    static let twoLinesKey = "floatingLyricsTwoLines"
    static var twoLines: Bool { UserDefaults.standard.bool(forKey: twoLinesKey) }

    func setTwoLines(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.twoLinesKey)
        if let panel { positionLyricPanel(for: tucked ? (shownFrame ?? panel.frame) : panel.frame) }
        positionIsland()
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
        let normalScale = Self.lyricBase(Self.size) * Self.lyricSize
        // 贴在上边：歌词放进菜单栏里，在球旁边（朝屏幕里面），上下在菜单栏正中；只显示一行，不要胶囊底，只有字
        if dock == .top, dragStart == nil, let screen = panel?.screen ?? NSScreen.main,
           case let bar = screen.frame.maxY - screen.visibleFrame.maxY, bar > 16 {
            if !lyricInMenuBar { lyricInMenuBar = true }
            if lyricCentered { lyricCentered = false }
            // 没有胶囊底，只有字，字号和菜单栏上的字差不多（13pt）
            let fit = min(normalScale, 13 / 14)
            if fit != lyricScale { lyricScale = fit }
            // 不挂在球的窗口上：鼠标移上去球滑出来时，字留在菜单栏里不跟着动
            if lyricPanel.parent != nil { lyricPanel.parent?.removeChildWindow(lyricPanel) }
            let onLeft = lyricSide(for: ball)
            if onLeft != lyricOnLeft { lyricOnLeft = onLeft }
            let gap: CGFloat = 16
            let x = onLeft ? ball.minX - gap - lyricWidth : ball.maxX + gap
            let height = bar - 2
            let y = screen.frame.maxY - bar / 2 - height / 2
            lyricPanel.setFrame(NSRect(x: x, y: y, width: lyricWidth, height: height), display: false)
            return
        }
        if lyricInMenuBar { lyricInMenuBar = false }
        if lyricScale != normalScale { lyricScale = normalScale }
        // 从菜单栏里出来：重新挂回球的窗口上，跟着球一起动
        if lyricPanel.parent == nil, let panel, panel.isVisible, lyricPanel.isVisible {
            panel.addChildWindow(lyricPanel, ordered: .above)
        }
        // 贴在下边（或者上边没有菜单栏时）：歌词条放在球的上面 / 下面，左右以球为中心，不出屏幕
        if dock == .top || dock == .bottom, dragStart == nil, let screen = panel?.screen ?? NSScreen.main {
            if !lyricCentered { lyricCentered = true }
            let visible = ball.intersection(screen.frame)
            let part = visible.isNull ? ball : visible
            let area = screen.visibleFrame
            let x = min(max(ball.midX - lyricWidth / 2, area.minX + 4), area.maxX - lyricWidth - 4)
            let y = dock == .top ? part.minY - lyricGap - lyricHeight : part.maxY + lyricGap
            lyricPanel.setFrame(NSRect(x: x, y: y, width: lyricWidth, height: lyricHeight), display: false)
            return
        }
        if lyricCentered { lyricCentered = false }
        let onLeft = lyricSide(for: ball)
        if onLeft != lyricOnLeft { lyricOnLeft = onLeft }
        let x = onLeft ? ball.minX - lyricGap - lyricWidth : ball.maxX + lyricGap
        // 上下和完整的球对齐
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

/// 刘海窗口要放到菜单栏那么高的位置，不让系统把它往下挪
private final class IslandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// 刘海上的歌词：拖动变回悬浮球（球出现在鼠标下，接着跟着拖），双击回主窗口，右键是球的菜单
private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    private var pressPoint: NSPoint?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        FloatingBall.shared.makeMenu()
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(FloatingBall.shared.makeMenu(), with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        pressPoint = NSEvent.mouseLocation
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressPoint else { return }
        let mouse = NSEvent.mouseLocation
        if !dragging {
            guard hypot(mouse.x - press.x, mouse.y - press.y) >= 4 else { return }
            dragging = true
            FloatingBall.shared.leaveIsland(dragFrom: mouse)
        }
        FloatingBall.shared.islandDragMoved(to: mouse)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressPoint = nil; dragging = false }
        if dragging {
            FloatingBall.shared.endDrag()
        } else if event.clickCount == 2 {
            FloatingBall.shared.exit()
        }
    }
}

struct FloatingBallView: View {
    @Environment(PlayerController.self) private var player
    private var hovering: Bool { FloatingBall.shared.hovering }

    /// 藏起一半时变小
    private var size: CGFloat { FloatingBall.shared.ballSize }
    /// 进度环粗细：跟着设置里的悬浮球大小一起变粗变细（贴边缩小时不变）
    private var ring: CGFloat { max(2, 3.5 * FloatingBall.shared.scale) }
    /// 进度头圆点的直径
    private var knob: CGFloat { ring * 1.8 }
    /// 进度环往里收这么多，圆点整个落在球里面，不会被圆形边缘裁掉半个
    private var ringInset: CGFloat { knob / 2 }
    /// 封面的主色：贴边藏起一半时给中间染色
    @State private var coverTint: Color?
    /// 进度环颜色：封面外圈深就用白色，浅就用黑色
    @State private var ringColor: Color = .white
    /// 藏起一半时进度环、音柱的颜色：不跟封面，跟球后面的深浅走（后面浅就用黑色，深就用白色）
    private var tuckColor: Color { FloatingBall.shared.backdropIsLight ? .black : .white }

    var body: some View {
        let fraction = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
        let provider = ArtworkProvider.shared
        ZStack {
            // 半透明玻璃底，透出一点封面的颜色（没封面时用很淡的底色），让进度环看得清
            // 半透明玻璃底；贴边藏起一半时不用系统玻璃（它不能调透明度），换成更透明的底色，进度环、音柱不变
            if FloatingBall.shared.tuckedEdge != nil {
                // 底色只铺在进度环里面（不超出那条线）
                Group {
                    Circle().fill(Theme.card.opacity(0.12))
                    Circle().fill(coverTint.map { $0.opacity(0.28) } ?? Theme.card.opacity(0.14))
                }
                .padding(ringInset + ring / 2)
                .allowsHitTesting(false)
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
        // 藏起一半时只画露出来的那半个（贴下边停在程序坞上沿时，另一半会压在程序坞上）；多留一点，进度起点的圆头不被切掉
        .mask(alignment: tuckedMaskAlignment) {
            if let edge = FloatingBall.shared.tuckedEdge {
                let keep = size / 2 + ring * 1.5
                Rectangle().frame(width: edge == .left || edge == .right ? keep : size,
                                  height: edge == .top || edge == .bottom ? keep : size)
            } else {
                Rectangle()
            }
        }
        .contentShape(Circle())
        // 拖动在 FloatingBall 里按鼠标事件处理；单击空白处显示播放队列（等双击时间过了才算单击），双击回主窗口
        .gesture(TapGesture(count: 2).onEnded { FloatingBall.shared.exit() }
            .exclusively(before: TapGesture().onEnded { FloatingBall.shared.toggleQueue() }))
        .help(player.current.map { "\($0.title) — \($0.artist)\n单击显示播放队列，双击回到主窗口" } ?? "双击回到主窗口")
    }

    /// 藏起一半时露出来的是哪一边（贴左边露右半边，贴上边露下半边……）
    private var tuckedMaskAlignment: Alignment {
        switch FloatingBall.shared.tuckedEdge {
        case .left: .trailing
        case .right: .leading
        case .top: .bottom
        case .bottom: .top
        case nil: .center
        }
    }

    /// 藏起一半时的样子（和 App 图标一样的配色）：不显示封面；
    /// 露出来的半圆边是整条进度（贴左右边时从上到下，贴上下边时从左到右），进度头上有个圆点；
    /// 中间播放时是三根跳动的音柱，暂停时是播放三角
    private func tuckedFace(edge: FloatingBall.DockEdge, fraction: Double) -> some View {
        // 贴右边时露出左半边，进度从顶部沿左边走到底部；贴左边时反过来。
        // 贴上边：把「贴右边」的样子逆时针转 90°，露出下半边，进度从左沿下边走到右；
        // 贴下边：把「贴左边」的样子逆时针转 90°，露出上半边，进度从左沿上边走到右
        let mirror: CGFloat = edge == .right || edge == .top ? -1 : 1
        let turn: Angle = edge == .top || edge == .bottom ? .degrees(-90) : .zero
        // 音柱、三角不转，往露出来的那一边挪
        let shift = size * 0.15
        let iconOffset: CGSize = switch edge {
        case .left: CGSize(width: shift, height: 0)
        case .right: CGSize(width: -shift, height: 0)
        case .top: CGSize(width: 0, height: shift)
        case .bottom: CGSize(width: 0, height: -shift)
        }
        return ZStack {
            ZStack {
                halfArc(to: 1, color: tuckColor.opacity(0.25), width: ring, inset: ringInset, mirror: mirror)
                halfArc(to: fraction, color: tuckColor, width: ring, inset: ringInset, mirror: mirror)
                progressKnob(angle: .pi * max(0, min(1, fraction)), mirror: mirror, color: tuckColor)
                    .opacity(fraction > 0.01 ? 1 : 0)
            }
            .rotationEffect(turn)

            Group {
                if player.isPlaying {
                    EqualizerBars(color: tuckColor)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(tuckColor)
                }
            }
            .scaleEffect(size / 80)   // 球缩小了，音柱和三角也跟着小一点
            .offset(iconOffset)
            .transition(.opacity)
        }
        // 进度环、音柱、三角都衬一圈反色的淡光：后面深浅判断错了（比如没有屏幕录制权限时）也看得出来
        .shadow(color: (FloatingBall.shared.backdropIsLight ? Color.white : Color.black).opacity(0.7), radius: 1.5)
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
    private func progressKnob(angle: Double, mirror: CGFloat = 1, color: Color? = nil) -> some View {
        let r = size / 2 - ringInset
        return Circle()
            .fill(color ?? ringColor)
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
    /// 暂停时不显示歌词（球旁边的胶囊藏起来，刘海胶囊改显示歌名和歌手）
    static let hideWhenPausedKey = "floatingLyricsHideWhenPaused"
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
    @AppStorage(FloatingLyricsMode.hideWhenPausedKey) private var hideWhenPaused = false
    @AppStorage(FloatingBall.twoLinesKey) private var twoLinesSetting = false
    /// 歌词条缩在菜单栏里时只显示一行
    private var twoLines: Bool { twoLinesSetting && !FloatingBall.shared.lyricInMenuBar }
    private var inBar: Bool { FloatingBall.shared.lyricInMenuBar }
    /// 菜单栏上的字的颜色：跟贴边半圆一样按后面的深浅反色（后面浅用黑字，深用白字）
    private var barTextColor: Color { FloatingBall.shared.backdropIsLight ? .black : .white }
    @AppStorage(FloatingBall.lyricCoverTintKey) private var coverTintOn = true
    /// 胶囊跟随封面颜色时用的封面色（菜单栏里没有底，不用）
    private var tint: Color? { coverTintOn && !inBar ? FloatingBall.shared.lyricTint : nil }
    /// 底色是页面底色为主、淡淡透一点封面色（和正在播放页的背景一样），字照常用主题的颜色
    private var currentTextColor: Color { Theme.text }
    private var otherTextColor: Color { Theme.text2 }
    /// 上一次胶囊里字的宽度，用来判断这次换句胶囊是变宽还是变窄
    @State private var lastTextWidth: CGFloat = 0

    var body: some View {
        let ball = FloatingBall.shared
        let s = ball.lyricScale
        // 调胶囊大小时没歌词也显示一条示例
        let preview = ball.adjustingLyric && currentLine.isEmpty
        let line = preview ? "歌词胶囊大小预览" : currentLine
        let next = preview ? "下一句歌词" : nextLine
        let visible = ball.adjustingLyric || (!line.isEmpty && player.playedThisLaunch && (ball.tuckedEdge == nil || showWhenTucked)
            && mode != .off && (mode == .always || ball.hovering) && (player.isPlaying || !hideWhenPaused))
        // 文字靠球那一边对齐
        let align: HorizontalAlignment = ball.lyricCentered ? .center : ball.lyricOnLeft ? .trailing : .leading
        let rowAlign: Alignment = ball.lyricCentered ? .center : ball.lyricOnLeft ? .trailing : .leading
        // 两行模式唱到最后一句（没有下一句了）时，胶囊缩回一行的高度
        let two = twoLines && !next.isEmpty
        // 胶囊贴着字：现在这句（大字）和下一句（显示出来的小字，14 号缩到 11/14）里宽的那个，最宽到整个歌词条
        let textWidth = min(max(1, ball.lyricWidth - 32 * s),
                            max(NotchIslandView.width(of: line, size: 14 * s, weight: .semibold),
                                two ? NotchIslandView.width(of: next, size: 14 * s, weight: .semibold) * 11 / 14 : 0))
        // 换句时：要变宽就先很快撑开，再让新的大字淡入，字不会被胶囊边切掉；
        // 要变窄就等旧的那句往上移走、淡得差不多了再收，不会看到边扫过还没淡掉的字
        let widthAnimation: Animation = textWidth > lastTextWidth
            ? .easeOut(duration: 0.18)
            : .easeInOut(duration: 0.25).delay(0.15)
        // 量大小用，不显示，只撑开胶囊（宽度按上面量好的，高度按一行 / 两行）
        Text(line).font(.ui(14 * s, .semibold)).lineLimit(1)
        .frame(width: textWidth, height: two ? 32 * s : nil)
        .opacity(0)
        // 真正显示的：前后几句排成一列，换句时整列往上推一行；
        // 下一句上移变成当前这句（小字淡出、大字淡入），旧的当前句往上移出、变淡
        .overlay(alignment: rowAlign) {
            if preview {
                VStack(alignment: align, spacing: 2 * s) {
                    Text(line).font(.ui(14 * s, .semibold)).foregroundStyle(currentTextColor).lineLimit(1)
                    if twoLines { Text(next).font(.ui(11 * s, .medium)).foregroundStyle(otherTextColor).lineLimit(1) }
                }
            } else {
                scrollingRows(scale: s, align: rowAlign, twoLines: two)
            }
        }
        .padding(.horizontal, inBar ? 2 : 16 * s)
        .padding(.vertical, two ? 8 * s : 0)
        .frame(minHeight: inBar ? 0 : (36 * s).rounded())
        .clipped()
        .background {
            // 在菜单栏里时不要胶囊底，只有字
            if !inBar {
                ZStack {
                    GlassBackground(cornerRadius: 18 * s)
                    // 跟随封面颜色：像正在播放页的背景，页面底色为主、淡淡透出封面色；不然是原来的淡底
                    if let tint {
                        RoundedRectangle(cornerRadius: 18 * s, style: .continuous).fill(Theme.bg.opacity(0.72))
                        RoundedRectangle(cornerRadius: 18 * s, style: .continuous).fill(tint.opacity(0.3))
                    } else {
                        RoundedRectangle(cornerRadius: 18 * s, style: .continuous).fill(Theme.card.opacity(0.35))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18 * s, style: .continuous))
        // 双击胶囊回主窗口
        .contentShape(RoundedRectangle(cornerRadius: 18 * s, style: .continuous))
        .onTapGesture(count: 2) { FloatingBall.shared.exit() }
        .allowsHitTesting(visible)
        .animation(widthAnimation, value: textWidth)
        .onChange(of: textWidth, initial: true) { _, w in lastTextWidth = w }
        .animation(.easeInOut(duration: 0.35), value: player.currentLyricIndex)
        // 贴着球那一边对齐，长度跟着歌词变，最长到整个歌词条；上下居中对齐球
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: rowAlign)
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: visible)
        // 胶囊不显示时整条歌词窗口都不接鼠标，不挡后面的东西
        .onChange(of: visible, initial: true) { _, shown in FloatingBall.shared.setLyricClickable(shown) }
        .task(id: player.current?.path) { await FloatingBall.shared.updateLyricTint(for: player.current) }
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
    private func scrollingRows(scale s: CGFloat, align: Alignment, twoLines: Bool) -> some View {
        let rows = textRows
        let current = shownIndex ?? -1
        // 当前句在 rows 里的位置（当前是空行时取它前面最近的一句）
        let pos = rows.lastIndex { $0.index <= current } ?? -1
        let pitch = (twoLines ? 19 : 26) * s
        // 两行时当前句在上半、下一句在下半；一行时当前句在正中
        let base = twoLines ? -pitch / 2 : 0
        let window = rows.indices.filter { $0 >= pos - 1 && $0 <= pos + 2 }
        // 每行都按胶囊最宽时排版（固定宽度，不跟着胶囊宽度的动画一起变），换句的时候字不会重新排、不会跳
        let full = max(1, FloatingBall.shared.lyricWidth - 32 * s)
        return GeometryReader { geo in
            ZStack(alignment: align) {
                ForEach(window, id: \.self) { k in
                    let isCurrent = k == pos
                    let isNext = twoLines && k == pos + 1
                    // 大字（当前句）和小字（下一句）各排一份、叠在同一个位置，换句时两份一起只往上移、互相淡入淡出。
                    // 移动的时候不缩放：靠球那一边对齐的缩放会让长句远离球的那头横着扫过去，看起来像走弧线
                    ZStack(alignment: align) {
                        rowText(rows[k].text, current: true, scale: s, width: full, align: align)
                            .opacity(isCurrent ? 1 : 0)
                        rowText(rows[k].text, current: false, scale: s, width: full, align: align)
                            .opacity(isNext ? 1 : 0)
                    }
                    .offset(y: base + CGFloat(k - pos) * pitch)
                    .transition(.opacity)
                }
            }
            // 换句时整列往上推用自己的动画；外面这层裁切框跟着胶囊宽度的动画走，不然新的大字会被还没撑开的框切掉
            .animation(.easeInOut(duration: 0.35), value: pos)
            .frame(width: geo.size.width, height: geo.size.height, alignment: align)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
    }

    /// 一行歌词：current 时是当前句的大字，不然是下一句的小字（缩到 11/14，靠球那一边对齐）
    private func rowText(_ text: String, current: Bool, scale s: CGFloat, width full: CGFloat, align: Alignment) -> some View {
        let small = 11.0 / 14.0
        return Text(text)
            .font(.ui(14 * s, .semibold))
            .foregroundStyle(inBar ? barTextColor.opacity(current ? 1 : 0.6) : current ? currentTextColor : otherTextColor)
            // 菜单栏上没有底，衬一圈很淡的反色光，背景花的时候也看得清
            .shadow(color: inBar ? barTextColor == .black ? .white.opacity(0.5) : .black.opacity(0.5) : .clear, radius: 1)
            .lineLimit(1)
            .truncationMode(.tail)
            // 字号换不出平滑动画，用缩放；排版时按缩放前的宽度给，缩完正好是胶囊的宽度，不会提前出省略号
            .frame(width: full / (current ? 1 : small), alignment: align)
            .scaleEffect(current ? 1 : small, anchor: align == .trailing ? .trailing : align == .center ? .center : .leading)
            .frame(width: full, alignment: align)
    }

    /// 胶囊当作「当前句」的那一行：一般就是正在唱的这句；
    /// 前奏里（还没到第一句有字的歌词）先把第一句有字的歌词当成当前句显示出来。没有逐句歌词时为 nil
    private var shownIndex: Int? { player.floatingLyricIndex }

    /// 当前这一句；没有逐句歌词时为空（不显示歌词条）
    private var currentLine: String {
        guard let i = shownIndex, player.lyrics.indices.contains(i) else { return "" }
        return player.lyrics[i].text.trimmingCharacters(in: .whitespaces)
    }

    /// 下一句（跳过空行）
    private var nextLine: String {
        guard player.lyricsState == .loaded else { return "" }
        let start = (shownIndex ?? -1) + 1
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

extension PlayerController {
    /// 悬浮球歌词胶囊 / 刘海歌词当作「当前句」的那一行：一般就是正在唱的这句；
    /// 前奏里（还没到第一句有字的歌词）先把第一句有字的歌词当成当前句。没有逐句歌词时为 nil
    var floatingLyricIndex: Int? {
        guard lyricsState == .loaded, lyrics.first?.time != nil else { return nil }
        let textIndices = lyrics.indices.filter { !lyrics[$0].text.isBlank }
        if let c = currentLyricIndex, textIndices.contains(where: { $0 <= c }) { return c }
        return textIndices.first
    }
}
