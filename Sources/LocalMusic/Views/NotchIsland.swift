import AppKit
import SwiftUI

/// 悬浮球吸附在刘海上时显示的东西：刘海下面隔一小段悬着一个歌词胶囊，样子和球旁边的歌词胶囊一样
/// （药丸形、字号跟着「歌词胶囊大小」），底是毛玻璃，按背后深浅换深色 / 浅色；开了「显示两行歌词」时下面再加淡一点的下一句。
/// 没有逐句歌词时显示歌名（两行时下面是歌手）。
struct NotchIslandView: View {
    @Environment(PlayerController.self) private var player
    @AppStorage(FloatingBall.twoLinesKey) private var twoLines = false
    @AppStorage(FloatingBall.lyricCoverTintKey) private var coverTintOn = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let ball = FloatingBall.shared
        let s = ball.lyricScale
        let notch = ball.islandNotchSize
        let open = ball.islandExpanded
        let (line, next) = lines
        // 两行模式唱到最后一句（没有下一句了）时，胶囊缩回一行的高度
        let twoLines = self.twoLines && !next.isEmpty
        let pad = 16 * s
        let textWidth = max(Self.width(of: line, size: 14 * s, weight: .semibold),
                            twoLines ? Self.width(of: next, size: 11 * s, weight: .medium) : 0)
        // 宽度跟着歌词长短走，换句时跟着变；最宽到 islandMaxWidth
        let capsuleWidth = min(ball.islandMaxWidth, max(60 * s, textWidth + pad * 2))
        // 跟随封面颜色：像正在播放页的背景，按 App 外观用深 / 浅毛玻璃，页面底色为主、淡淡透出封面色；
        // 不跟随：后面浅就用深色毛玻璃 + 浅色字，后面深就用浅色毛玻璃 + 深色字
        let tint = coverTintOn ? ball.lyricTint : nil
        let dark = tint != nil ? colorScheme == .dark : ball.islandBackdropLight
        let height = twoLines ? ball.islandContentHeight : (36 * s).rounded()
        let radius = 18 * s

        // 歌词、毛玻璃都按最宽的胶囊排版、放在正中间，宽度一直不变；
        // 只有外面那层圆角遮罩跟着歌词变宽变窄。这样换句时字和底都不会先靠左再跳回中间
        let full = ball.islandMaxWidth
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            ZStack {
                FrostBackground(dark: dark)
                if let tint {
                    Rectangle().fill(Theme.bg.opacity(0.72))
                    Rectangle().fill(tint.opacity(0.3))
                } else {
                    Rectangle().fill(dark ? Color.black.opacity(0.28) : Color.white.opacity(0.35))
                }
            }
            .frame(width: full, height: height)
            if let (rows, pos) = lyricRows {
                // 有逐句歌词：和悬浮球旁边的胶囊一样，前后几句排成一列，换句时整列往上推一行；
                // 下一句一边上移一边放大变亮成为当前句，旧的当前句往上移出、变淡
                scrollingRows(rows, pos: pos, scale: s, width: full - pad * 2, height: height, dark: dark, twoLines: twoLines)
                    .frame(width: full, height: height)
                    .clipped()
            } else {
            VStack(spacing: 2 * s) {
                // 换句时新的一句从下面滑上来、旧的往上滑走
                ZStack {
                    Text(line)
                        .font(.ui(14 * s, .semibold))
                        .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: full - pad * 2)
                        .id(line)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .move(edge: .top).combined(with: .opacity)))
                }
                if twoLines {
                    Text(next)
                        .font(.ui(11 * s, .medium))
                        .foregroundStyle(dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: full - pad * 2)
                        .id(next)
                        .transition(.opacity)
                }
            }
            .frame(width: full, height: height)
            .clipped()
            }
        }
        .frame(width: full, height: height)
        .mask { shape.frame(width: capsuleWidth, height: height) }
        // 细边 + 淡阴影，背后和胶囊颜色接近时也分得出边
        .overlay {
            shape
                .strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 0.5)
                .frame(width: capsuleWidth, height: height)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(dark ? 0.25 : 0.18), radius: 5, y: 2)
        .animation(.easeInOut(duration: 0.35), value: line)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: capsuleWidth)
        // 从刘海里弹出来：收着的时候缩小、往上躲进刘海、透明
        .scaleEffect(open ? 1 : 0.4, anchor: .top)
        .offset(y: open ? 0 : -(FloatingBall.islandGap + height / 2))
        .opacity(open ? 1 : 0)
        .padding(.top, notch.height + FloatingBall.islandGap)
        .task(id: player.current?.path) { await FloatingBall.shared.updateLyricTint(for: player.current) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .help("双击打开主窗口，往下拖变回悬浮球")
    }

    /// 有逐句歌词时：有字的歌词行，和当前句在里面的位置（前奏里是第一句，间奏里是前面最近的一句）
    private var lyricRows: ([String], Int)? {
        guard player.current != nil, let i = player.floatingLyricIndex else { return nil }
        let rows = player.lyrics.enumerated().compactMap { k, l -> (index: Int, text: String)? in
            let t = l.text.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : (k, t)
        }
        guard let pos = rows.lastIndex(where: { $0.index <= i }) else { return nil }
        return (rows.map(\.text), pos)
    }

    /// 当前句前后几行，每行按「离当前句差几行」往上 / 往下摆，换句时一起动起来，看起来就是整列往上推
    private func scrollingRows(_ rows: [String], pos: Int, scale s: CGFloat, width: CGFloat, height: CGFloat,
                               dark: Bool, twoLines: Bool) -> some View {
        let pitch = (twoLines ? 19 : 26) * s
        // 两行时当前句在上半、下一句在下半；一行时当前句在正中
        let base = twoLines ? -pitch / 2 : 0
        let window = rows.indices.filter { $0 >= pos - 1 && $0 <= pos + 2 }
        let small = 11.0 / 14.0
        return ZStack {
            ForEach(window, id: \.self) { k in
                let isCurrent = k == pos
                let shown = isCurrent || (twoLines && k == pos + 1)
                Text(rows[k])
                    .font(.ui(14 * s, .semibold))
                    .foregroundStyle(isCurrent ? (dark ? Color.white : Color.black.opacity(0.85))
                                               : (dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 字号换不出平滑动画，用缩放：不是当前句时缩到 11/14；排版时按缩放前的宽度给，缩完正好是可用的宽度
                    .frame(width: width / (isCurrent ? 1 : small))
                    .scaleEffect(isCurrent ? 1 : small)
                    .frame(width: width)
                    .opacity(shown ? 1 : 0)
                    .offset(y: base + CGFloat(k - pos) * pitch)
            }
        }
        .frame(width: width, height: height)
        .animation(.easeInOut(duration: 0.35), value: pos)
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

/// 刘海歌词胶囊的毛玻璃：把后面的东西模糊掉；dark 时用深色外观，不然用浅色外观
private struct FrostBackground: NSViewRepresentable {
    var dark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = FrostView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    private final class FrostView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
