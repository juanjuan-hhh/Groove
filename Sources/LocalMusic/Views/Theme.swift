import AppKit
import SwiftUI

/// 配色和样式，取自 Porthole（舷窗）监控屏：黑底、奶油色文字，
/// 加五种低饱和颜色（石板蓝、青绿、赭橙、芥末黄、鼠尾草绿）做纯色胶囊。
/// 每个颜色有深色、浅色两版，跟着「外观」设置切换（见 AppearanceMode）。
enum Theme {
    // MARK: 底色和文字                       深色版              浅色版

    static let bg = dynamic(0x000000, 0xFFFFFF)       // 页面背景：纯黑 / 纯白
    static let card = dynamic(0x16171B, 0xF5F2EC)     // 卡片、底部播放条、搜索框
    static let surface = dynamic(0x24252B, 0xECE8E0)  // 悬停、空闲的胶囊
    static let track = dynamic(0x2E3036, 0xE3DED4)    // 进度条空的部分
    static let line = dynamic(0x24252B, 0xECE8E0)     // 分隔线
    static let text = dynamic(0xF2E9D8, 0x1C1D21)     // 正文：奶油色 / 墨色
    static let text2 = dynamic(0x9C9384, 0x6E675C)    // 说明文字
    static let text3 = dynamic(0x5C574F, 0xA9A296)    // 更淡的文字
    static let ink = Color(hex: 0x1C1D21)             // 浅色胶囊上的深色字（两版一样）
    static let cream = Color(hex: 0xF2E9D8)           // 深色胶囊（石板蓝、青绿）上的浅色字（两版一样）

    // MARK: 五种颜色（浅色版稍微深一点，白底上看得清）

    static let slate = Color(hex: 0x59718A)              // 石板蓝
    static let teal = Color(hex: 0x2F6F6D)               // 青绿
    static let terra = dynamic(0xE07A47, 0xC8622F)       // 赭橙
    static let mustard = dynamic(0xD4A72C, 0xC9961A)     // 芥末黄
    static let sage = dynamic(0x8FA68F, 0x6B8C6B)        // 鼠尾草绿

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
        Rectangle().fill(Theme.line).frame(height: 1)
    }
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
    private let sweep = 1.7, cycle = 3.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
            let band = min(88, width * 0.6)
            let x = t < sweep ? -band + (width + band) * (t / sweep) : -band * 2
            LinearGradient(colors: [Theme.shine.opacity(0), Theme.shine.opacity(0.5), Theme.shine.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: band, height: height)
                .offset(x: x)
                .frame(width: width, height: height, alignment: .leading)
        }
        .allowsHitTesting(false)
    }
}

/// 放在顶栏背后：空白处可以拖动窗口，双击铺满屏幕 / 恢复（见 WindowFill）。按钮、搜索框在它上面，不受影响
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                if let window { WindowFill.handleDoubleClick(window) }
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
