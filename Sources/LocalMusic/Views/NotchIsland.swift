import AppKit
import SwiftUI

/// 悬浮球吸附在刘海上时显示的东西：刘海往下长出一块纯黑的底（和刘海连成一片），里面是当前这句歌词
/// （开了「显示两行歌词」时下面再加淡一点的下一句）。没有逐句歌词时显示歌名（两行时下面是歌手）。
struct NotchIslandView: View {
    @Environment(PlayerController.self) private var player
    @AppStorage(FloatingBall.twoLinesKey) private var twoLines = false

    var body: some View {
        let ball = FloatingBall.shared
        let s = ball.lyricScale
        let notch = ball.islandNotchSize
        let open = ball.islandExpanded
        let (line, next) = lines
        let pad = 18 * s
        let textWidth = max(Self.width(of: line, size: 14 * s, weight: .semibold),
                            twoLines ? Self.width(of: next, size: 11.5 * s, weight: .medium) : 0)
        // 至少和刘海一样宽，歌词长就往两边变宽，最宽到 islandMaxWidth
        let bodyWidth = open ? min(ball.islandMaxWidth, max(notch.width, textWidth + pad * 2)) : notch.width
        let contentHeight = ball.islandContentHeight
        let ear = open ? FloatingBall.islandEar : 0

        NotchShape(ear: ear, radius: open ? 16 * s : 8)
            .fill(Color.black)
            .frame(width: bodyWidth + ear * 2, height: notch.height + (open ? contentHeight : 0))
            .overlay(alignment: .bottom) {
                VStack(spacing: 2 * s) {
                    // 换句时新的一句从下面滑上来、旧的往上滑走
                    ZStack {
                        Text(line)
                            .font(.ui(14 * s, .semibold))
                            .foregroundStyle(Theme.cream)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .id(line)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .move(edge: .top).combined(with: .opacity)))
                    }
                    if twoLines {
                        Text(next)
                            .font(.ui(11.5 * s, .medium))
                            .foregroundStyle(Theme.cream.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .id(next)
                            .transition(.opacity)
                    }
                }
                .frame(width: max(0, bodyWidth - pad * 2 + 8 * s), height: contentHeight)
                .clipped()
                .opacity(open ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.35), value: line)
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: bodyWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .help("双击打开主窗口，往下拖变回悬浮球")
    }

    /// 显示的两行：有逐句歌词时是当前句（前奏里先显示第一句）+ 下一句，跳过空行；
    /// 没有逐句歌词时是歌名 + 歌手；什么都没在放时显示「未在播放」
    private var lines: (String, String) {
        guard let track = player.current else { return ("未在播放", "") }
        if let i = player.floatingLyricIndex {
            let rows = player.lyrics.enumerated().compactMap { k, l -> (index: Int, text: String)? in
                let t = l.text.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : (k, t)
            }
            // 当前是空行（间奏）时接着显示前面最近的一句
            if let pos = rows.lastIndex(where: { $0.index <= i }) {
                return (rows[pos].text, pos + 1 < rows.count ? rows[pos + 1].text : "")
            }
        }
        return (track.title, track.artist)
    }

    /// 量一行字有多宽（和 .ui 一样用圆体），黑底按它变宽
    private static func width(of text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if let rounded = font.fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: rounded, size: size) ?? font
        }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// 刘海延伸出来的形状：顶边贴着屏幕，两个上角往外翘一点小弧接到屏幕边上（像真的刘海），下面两个角是圆角
struct NotchShape: Shape {
    var ear: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let e = min(ear, h / 2)
        let r = max(0, min(radius, (w - e * 2) / 2, h - e))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + e, y: rect.minY + e), control: CGPoint(x: rect.minX + e, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + e, y: rect.minY + h - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + e + r, y: rect.minY + h), control: CGPoint(x: rect.minX + e, y: rect.minY + h))
        p.addLine(to: CGPoint(x: rect.minX + w - e - r, y: rect.minY + h))
        p.addQuadCurve(to: CGPoint(x: rect.minX + w - e, y: rect.minY + h - r), control: CGPoint(x: rect.minX + w - e, y: rect.minY + h))
        p.addLine(to: CGPoint(x: rect.minX + w - e, y: rect.minY + e))
        p.addQuadCurve(to: CGPoint(x: rect.minX + w, y: rect.minY), control: CGPoint(x: rect.minX + w - e, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
