import AppKit
import SwiftUI

/// 悬浮球吸附在刘海上时显示的东西：刘海下面隔一小段悬着一个歌词胶囊，样子和球旁边的歌词胶囊一样
/// （玻璃底、字号跟着「歌词胶囊大小」）；开了「显示两行歌词」时下面再加淡一点的下一句。
/// 没有逐句歌词时显示歌名（两行时下面是歌手）。
struct NotchIslandView: View {
    @Environment(PlayerController.self) private var player
    @AppStorage(FloatingBall.twoLinesKey) private var twoLines = false

    var body: some View {
        let ball = FloatingBall.shared
        let s = ball.lyricScale
        let notch = ball.islandNotchSize
        let open = ball.islandExpanded
        let (line, next) = lines
        let pad = 16 * s
        let textWidth = max(Self.width(of: line, size: 14 * s, weight: .semibold),
                            twoLines ? Self.width(of: next, size: 11 * s, weight: .medium) : 0)
        // 至少和刘海一样宽，歌词长就往两边变宽，最宽到 islandMaxWidth
        let capsuleWidth = min(ball.islandMaxWidth, max(notch.width, textWidth + pad * 2))
        let height = ball.islandContentHeight
        let radius = 18 * s

        VStack(spacing: 2 * s) {
            // 换句时新的一句从下面滑上来、旧的往上滑走
            ZStack {
                Text(line)
                    .font(.ui(14 * s, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(line)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .move(edge: .top).combined(with: .opacity)))
            }
            if twoLines {
                Text(next)
                    .font(.ui(11 * s, .medium))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(next)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, pad)
        .frame(width: capsuleWidth, height: height)
        .clipped()
        .background {
            ZStack {
                GlassBackground(cornerRadius: radius)
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card.opacity(0.35))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .animation(.easeInOut(duration: 0.35), value: line)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: capsuleWidth)
        // 从刘海里弹出来：收着的时候缩小、往上躲进刘海、透明
        .scaleEffect(open ? 1 : 0.4, anchor: .top)
        .offset(y: open ? 0 : -(FloatingBall.islandGap + height / 2))
        .opacity(open ? 1 : 0)
        .padding(.top, notch.height + FloatingBall.islandGap)
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
