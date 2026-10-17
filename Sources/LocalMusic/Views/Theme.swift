import AppKit
import SwiftUI

/// 配色和样式，取自 Porthole（舷窗）监控屏：黑底、奶油色文字，
/// 加五种低饱和颜色（石板蓝、青绿、赭橙、芥末黄、鼠尾草绿）做纯色胶囊。
/// 每个颜色有深色、浅色两版，跟着「外观」设置切换（见 AppearanceMode）。
enum Theme {
    // MARK: 底色和文字                       深色版              浅色版

    static let bg = dynamic(0x000000, 0xFAF8F4)       // 页面背景：纯黑 / 淡暖白
    static let card = dynamic(0x16171B, 0xF5F2EC)     // 卡片、底部播放条、搜索框
    static let surface = dynamic(0x24252B, 0xECE8E0)  // 悬停、空闲的胶囊
    static let track = dynamic(0x2E3036, 0xE3DED4)    // 进度条空的部分
    static let line = dynamic(0x24252B, 0xECE8E0)     // 分隔线
    static let text = dynamic(0xF2E9D8, 0x1C1D21)     // 正文：奶油色 / 墨色
    static let text2 = dynamic(0x9C9384, 0x6E675C)    // 说明文字
    static let text3 = dynamic(0x5C574F, 0xA9A296)    // 更淡的文字
    static let ink = Color(hex: 0x1C1D21)             // 浅色胶囊上的深色字（两版一样）
    static let cream = Color(hex: 0xF2E9D8)           // 深色胶囊（石板蓝、青绿）上的浅色字（两版一样）
    static let onText = dynamic(0x1C1D21, 0xFFFFFF)   // 用正文色当底色时上面的字（选中的分类按钮）

    // MARK: 五种颜色（浅色版稍微深一点，白底上看得清）

    static let slate = Color(hex: 0x59718A)              // 石板蓝
    static let teal = Color(hex: 0x2F6F6D)               // 青绿
    static let terra = dynamic(0xE07A47, 0xC8622F)       // 赭橙
    static let mustard = dynamic(0xD4A72C, 0xC9961A)     // 芥末黄
    static let sage = dynamic(0x8FA68F, 0x6B8C6B)        // 鼠尾草绿

    // MARK: 用了自定义背景图时（背景是图片，不是纯色）：分隔线换成淡淡的亮线，最淡的文字提亮一档，免得看不清

    @MainActor static var hasBackgroundImage: Bool { AppBackground.shared.image != nil }
    /// 分隔线
    @MainActor static var divider: Color { hasBackgroundImage ? text.opacity(0.12) : line }
    /// 表头、占位字这类最淡的文字
    @MainActor static var faint: Color { hasBackgroundImage ? text2 : text3 }
    /// 鼠标放上去的那一行、正在放的那一行、小标签的底：背景是图片时半透明，透出背景
    @MainActor static var rowHover: Color { hasBackgroundImage ? card.opacity(0.45) : surface }
    @MainActor static var rowCurrent: Color { hasBackgroundImage ? card.opacity(0.35) : card }
    @MainActor static var chip: Color { hasBackgroundImage ? surface.opacity(0.55) : surface }
    @MainActor static var panel: Color { hasBackgroundImage ? card.opacity(0.5) : card }

    /// 说明文字（歌手、专辑、格式、时长……）：背景是图片时用正文色压淡一点，比固定的灰色更看得清
    @MainActor static var secondary: Color { hasBackgroundImage ? text.opacity(0.75) : text2 }

    /// 主强调色：正在播放、播放按钮、进度
    static let accent = terra
    /// 进度条上滑过的光带
    static let shine = Color(hex: 0xFFF6E6)

    /// 深色外观用 dark，浅色外观用 light
    private static func dynamic(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    // MARK: 圆角

    static let rowRadius: CGFloat = 12
    static let cardRadius: CGFloat = 22
    static let artRadius: CGFloat = 8
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 外观：深色 / 浅色 / 跟随系统（齿轮菜单里切换）
enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: Self { self }

    static let key = "appearance"

    var label: String {
        switch self {
        case .dark: return "深色"
        case .light: return "浅色"
        case .system: return "跟随系统"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    /// 菜单、弹窗、浮窗这些 AppKit 部分也要跟着变
    var nsAppearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }

    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dark
    }
}

/// 按「外观」设置给一个窗口（主窗口、联网搜索面板）设定深浅色
struct ThemedAppearance: ViewModifier {
    @AppStorage(AppearanceMode.key) private var mode: AppearanceMode = .dark

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(mode.colorScheme)
            .onAppear { NSApp.appearance = mode.nsAppearance }
            .onChange(of: mode) { _, newValue in NSApp.appearance = newValue.nsAppearance }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension Font {
    /// Porthole 用的是圆体（Resource Han Rounded / Nunito），这里用系统圆体
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// 细分隔线
struct ThemeDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }
}

/// 用了自定义背景图时给图标按钮垫一个小的半透明圆底（深色外观垫黑、浅色外观垫白），
/// 背景是橙色、红色之类的图时按钮也看得出来；颜色不变，没用背景图时什么都不加
struct IconBacking: ViewModifier {
    let diameter: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background {
            if Theme.hasBackgroundImage {
                Circle()
                    .fill(scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.55))
                    .frame(width: diameter, height: diameter)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func iconBacking(_ diameter: CGFloat) -> some View { modifier(IconBacking(diameter: diameter)) }
}

/// 纯色胶囊里的一段文字（Porthole 的标题 / 标签样式）
struct ChipText: View {
    let text: String
    let color: Color
    var foreground: Color = Theme.ink
    var font: Font = .ui(12, .bold)
    var hPad: CGFloat = 10
    var vPad: CGFloat = 4

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(foreground)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(Capsule().fill(color))
    }
}

/// 粗胶囊进度条，可选在已填充部分上滑过一道光带（Porthole 额度条的动画）
struct CapsuleBar: View {
    let value: Double   // 0...1
    var color: Color = Theme.accent
    var height: CGFloat = 6
    var shimmer = false

    var body: some View {
        GeometryReader { geo in
            let v = min(1, max(0, value))
            let fillWidth = v > 0 ? max(height, geo.size.width * v) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color)
                    .frame(width: fillWidth)
                    .overlay(alignment: .leading) {
                        if shimmer && fillWidth > height * 2 {
                            ShineBand(width: fillWidth, height: height)
                                .clipShape(Capsule())
                        }
                    }
            }
        }
        .frame(height: height)
    }
}

/// 光带：1.7 秒滑过一次，然后停一会儿，3.5 秒一个周期
private struct ShineBand: View {
    let width: CGFloat
    let height: CGFloat

    /// 光带的三个阶段：回到左边 → 1.7 秒滑过 → 停 1.8 秒
    private enum Phase: CaseIterable { case start, sweep, rest }

    var body: some View {
        let band = min(88, width * 0.6)
        // 用 SwiftUI 动画插值，不用每帧重算界面
        LinearGradient(colors: [Theme.shine.opacity(0), Theme.shine.opacity(0.5), Theme.shine.opacity(0)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(width: band, height: height)
            .phaseAnimator(Phase.allCases) { content, phase in
                content.offset(x: phase == .start ? -band : width + (phase == .rest ? 1 : 0))
            } animation: { phase in
                switch phase {
                case .start: return nil                  // 瞬间回到左边
                case .sweep: return .linear(duration: 1.7)
                case .rest: return .linear(duration: 1.8)   // 在右边外面等着
                }
            }
            .frame(width: width, height: height, alignment: .leading)
            .allowsHitTesting(false)
    }
}

/// 放在顶栏背后：空白处可以拖动窗口，双击铺满屏幕 / 恢复（见 WindowFill）。按钮、搜索框在它上面，不受影响
struct WindowDragArea: NSViewRepresentable {
    /// 不传就按标题栏的规则：铺满 / 恢复（见 WindowFill）
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DragView else { return }
        view.onDoubleClick = onDoubleClick
    }

    private final class DragView: NSView, DragRegionProviding {
        var onDoubleClick: (() -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // 关掉系统自己拖窗口（隐藏标题栏的 SwiftUI 窗口，顶上一块是系统直接拖的，Groove 收不到鼠标）。
            // 系统拖在窗口差不多和屏幕一样大时，跨屏那一下会把窗口硬推到屏幕边上，之后一直偏着，离鼠标越来越远。
            // 改成 WindowDragger 自己挪
            window.isMovable = false
            WindowDragger.install()
        }

        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2 else { return super.mouseDown(with: event) }
            if let onDoubleClick {
                onDoubleClick()
            } else if let window {
                WindowFill.handleDoubleClick(window)
            }
        }

        /// 这块在窗口里占的范围，往上一直算到窗口顶（包括红绿灯那一条）
        func dragRegion() -> NSRect? {
            guard let window, !isHiddenOrHasHiddenAncestor, bounds.width > 0 else { return nil }
            let r = convert(bounds, to: nil)
            return NSRect(x: r.minX, y: r.minY, width: r.width, height: window.frame.height - r.minY)
        }
    }
}

/// 能拖动窗口的区域（WindowDragArea 里的 DragView）
@MainActor
protocol DragRegionProviding: AnyObject {
    func dragRegion() -> NSRect?
}

/// 主窗口拖动：按在顶栏（或正在播放页顶部）的空白处、按钮上都行，鼠标移动超过 3 点才开始拖；
/// 每一步窗口位置 = 鼠标全局位置 − 按下时鼠标在窗口里的位置，鼠标抓哪儿窗口就一直粘在哪儿，跨屏也不偏。
/// 搜索框里按下不拖（留给选文字）
@MainActor
enum WindowDragger {
    private static var monitor: Any?
    private static var press: (window: NSWindow, mouse: NSPoint, grab: NSPoint)?
    private static var dragging = false

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            nonisolated(unsafe) let incoming = event
            nonisolated(unsafe) var result: NSEvent? = event
            MainActor.assumeIsolated { result = handle(incoming) }
            return result
        }
    }

    private static func handle(_ event: NSEvent) -> NSEvent? {
        let mouse = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            press = nil
            dragging = false
            guard event.clickCount == 1, let window = event.window, !window.isMovable,
                  !(window.styleMask.contains(.fullScreen)), inDragRegion(event, window) else { return event }
            press = (window, mouse, NSPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY))
            return event
        case .leftMouseDragged:
            guard let press else { return event }
            if !dragging {
                guard hypot(mouse.x - press.mouse.x, mouse.y - press.mouse.y) >= 3 else { return event }
                dragging = true
            }
            let origin = NSPoint(x: (mouse.x - press.grab.x).rounded(), y: (mouse.y - press.grab.y).rounded())
            if press.window.frame.origin != origin { press.window.setFrameOrigin(origin) }
            return nil
        case .leftMouseUp:
            defer { press = nil; dragging = false }
            guard dragging else { return event }
            // 拖完松手的位置可能正好在按钮上：把这次松开挪到窗口外面，按钮就不会被误点
            return NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10000, y: -10000),
                                      modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                      windowNumber: event.windowNumber, context: nil,
                                      eventNumber: event.eventNumber, clickCount: event.clickCount,
                                      pressure: event.pressure)
        default:
            return event
        }
    }

    /// 按在某个拖动区里，而且不是在输入框里
    private static func inDragRegion(_ event: NSEvent, _ window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        let point = event.locationInWindow
        if let hit = content.superview?.hitTest(point) ?? content.hitTest(point), hit is NSText || hit is NSTextField {
            return false
        }
        return dragViews(in: content).contains { $0.dragRegion()?.contains(point) ?? false }
    }

    private static func dragViews(in view: NSView) -> [NSView & DragRegionProviding] {
        var found: [NSView & DragRegionProviding] = []
        if let v = view as? NSView & DragRegionProviding { found.append(v) }
        for sub in view.subviews { found += dragViews(in: sub) }
        return found
    }
}
