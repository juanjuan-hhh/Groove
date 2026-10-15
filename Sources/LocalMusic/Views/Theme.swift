import AppKit
import SwiftUI

/// 配色和样式，取自 Porthole（舷窗）监控屏：黑底、奶油色文字，
/// 加五种低饱和颜色（石板蓝、青绿、赭橙、芥末黄、鼠尾草绿）做纯色胶囊。
enum Theme {
    // MARK: 底色和文字

    static let bg = Color(hex: 0x000000)       // 页面背景：纯黑
    static let card = Color(hex: 0x16171B)     // 卡片、底部播放条、搜索框
    static let surface = Color(hex: 0x24252B)  // 悬停、空闲的胶囊
    static let track = Color(hex: 0x2E3036)    // 进度条空的部分
    static let line = Color(hex: 0x24252B)     // 分隔线
    static let text = Color(hex: 0xF2E9D8)     // 奶油色正文
    static let text2 = Color(hex: 0x9C9384)    // 说明文字（暗一点的奶油色）
    static let text3 = Color(hex: 0x5C574F)    // 更淡的文字
    static let ink = Color(hex: 0x1C1D21)      // 浅色胶囊上的深色字

    // MARK: 五种颜色

    static let slate = Color(hex: 0x59718A)    // 石板蓝
    static let teal = Color(hex: 0x2F6F6D)     // 青绿
    static let terra = Color(hex: 0xE07A47)    // 赭橙
    static let mustard = Color(hex: 0xD4A72C)  // 芥末黄
    static let sage = Color(hex: 0x8FA68F)     // 鼠尾草绿

    /// 主强调色：正在播放、播放按钮、进度
    static let accent = terra
    /// 进度条上滑过的光带
    static let shine = Color(hex: 0xFFF6E6)

    // MARK: 圆角

    static let rowRadius: CGFloat = 12
    static let cardRadius: CGFloat = 22
    static let artRadius: CGFloat = 8
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

/// 放在顶栏背后：空白处可以拖动窗口，双击缩放（和标题栏一样）。按钮、搜索框在它上面，不受影响
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                // 跟随系统设置「连按窗口标题栏以…」：缩放或最小化
                if UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") == "Minimize" {
                    window?.performMiniaturize(nil)
                } else {
                    window?.performZoom(nil)
                }
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
