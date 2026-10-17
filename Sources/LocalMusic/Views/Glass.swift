import AppKit
import SwiftUI

/// 半透明玻璃底：macOS 26 起用系统的 Liquid Glass（NSGlassEffectView），更早的系统用毛玻璃。
/// 不接收鼠标，点击和拖动交给上面的 SwiftUI。
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        let container = PassthroughView()
        let glass: NSView
        if #available(macOS 26, *) {
            let view = NSGlassEffectView()
            view.cornerRadius = cornerRadius
            glass = view
        } else {
            let view = NSVisualEffectView()
            view.material = .hudWindow
            view.blendingMode = .behindWindow
            view.state = .active
            view.wantsLayer = true
            view.layer?.cornerRadius = cornerRadius
            view.layer?.masksToBounds = true
            glass = view
        }
        glass.frame = container.bounds
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 主窗口的毛玻璃底：透出一点桌面壁纸。上面再盖一层半透明的底色（Theme.bg），文字照样看得清。
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = GlassView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class GlassView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        // 窗口本身要是透明的，后面的壁纸才透得过来
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}

/// 主窗口的自定义背景图（设置菜单里选）。没选时用默认的毛玻璃
@MainActor
@Observable
final class AppBackground {
    static let shared = AppBackground()
    private(set) var image: NSImage?
    /// 图片从上到下分成 12 条，每条的平均亮度（0…1）。用来算每一条至少要压多暗 / 提多亮，字才看得清
    private(set) var profile: [Double] = []
    private static let file = AppPaths.support.appendingPathComponent("background-image")
    private static let bands = 12

    /// 模糊（0…30）和透明度（盖在图片上的底色有多浓，0…0.9；越大图片越淡）
    static let blurRange: ClosedRange<Double> = 0...30
    static let dimRange: ClosedRange<Double> = 0...0.9
    static let defaultBlur = 6.0
    static let defaultDim = 0.62
    private static let blurKey = "backgroundBlur"
    private static let dimKey = "backgroundDim"
    var blur: Double = UserDefaults.standard.object(forKey: AppBackground.blurKey) as? Double ?? AppBackground.defaultBlur {
        didSet { UserDefaults.standard.set(blur, forKey: Self.blurKey) }
    }
    var dim: Double = UserDefaults.standard.object(forKey: AppBackground.dimKey) as? Double ?? AppBackground.defaultDim {
        didSet { UserDefaults.standard.set(dim, forKey: Self.dimKey) }
    }
    @ObservationIgnored private var adjustPanel: NSPanel?
    private static let adjustOriginKey = "backgroundAdjustOrigin"

    private init() {
        if let data = try? Data(contentsOf: Self.file) { setImage(Self.decode(data)) }
    }

    private func setImage(_ image: NSImage?) {
        self.image = image
        profile = image.map(Self.brightnessProfile) ?? []
    }

    /// 每一条的平均亮度：缩成 16×12 的小图来算，很快
    private static func brightnessProfile(_ image: NSImage) -> [Double] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let w = 16, h = bands
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // 内存里第一行是图片最上面
        return (0..<h).map { row in
            (0..<w).reduce(0.0) { sum, col in
                let i = (row * w + col) * 4
                return sum + (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
            } / Double(w)
        }
    }

    /// 盖在图片上的底色从上到下每一处多浓：至少是「透明度」设的值；图片太亮（深色外观，奶油色字）
    /// 或太暗（浅色外观，墨色字）的地方自动再加浓到字看得清为止
    func scrimLevels(dark: Bool) -> [Double] {
        guard !profile.isEmpty else { return [dim] }
        return profile.map { max(dim, Self.needed(brightness: $0, dark: dark)) }
    }

    /// 这块亮度的图片上面，至少盖多浓的底色：深色外观盖黑色，盖完亮度不超过 0.38；
    /// 浅色外观盖暖白色（亮度约 0.97），盖完亮度不低于 0.8
    private static func needed(brightness l: Double, dark: Bool) -> Double {
        if dark { return l <= 0.38 ? 0 : 1 - 0.38 / l }
        return l >= 0.8 ? 0 : (0.8 - l) / (0.97 - l)
    }

    /// 缩到不超过 3000 像素，大照片不占太多内存
    private static func decode(_ data: Data) -> NSImage? {
        guard let cg = ArtworkProvider.downsample(data, maxPixel: 3000) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "选一张图片当 Groove 主窗口的背景"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), let image = Self.decode(data) else { return }
        try? data.write(to: Self.file, options: .atomic)
        setImage(image)
    }

    func reset() {
        try? FileManager.default.removeItem(at: Self.file)
        setImage(nil)
        closeAdjuster()
    }

    /// 「调整模糊和透明度…」：主窗口下方弹一张小卡片，拖滑块马上看到效果
    func showAdjuster() {
        let panel = adjustPanel ?? makeAdjustPanel()
        adjustPanel = panel
        let main = NSApp.windows.first { !($0 is NSPanel) && $0.isVisible && $0.canBecomeMain }
        // 上次拖到哪儿就还在哪儿（那块屏幕还在的话），不然放在主窗口下方
        if let saved = UserDefaults.standard.string(forKey: Self.adjustOriginKey).map(NSPointFromString),
           NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSRect(origin: saved, size: panel.frame.size)) }) {
            panel.setFrameOrigin(saved)
        } else if let frame = main?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 110))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
    }

    func closeAdjuster() {
        adjustPanel?.orderOut(nil)
    }

    private func makeAdjustPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        // 按住标题那一行拖动（WindowDragArea），滑块照常拖；拖完记住位置
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: AppBackground.adjustOriginKey)
        }
        let host = NSHostingView(rootView: BackgroundAdjustView().modifier(ThemedAppearance()))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        return panel
    }
}

/// 调整背景图模糊、透明度的小卡片（和悬浮球「调大小」卡片一个样子）
private struct BackgroundAdjustView: View {
    @Bindable private var background = AppBackground.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("调整背景图片").font(.ui(14, .bold))
                Spacer()
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .contentShape(Rectangle())
            .background(WindowDragArea(onDoubleClick: {}))
            .help("按住这一行拖动")
            row("模糊", value: $background.blur, range: AppBackground.blurRange,
                label: "\(Int(background.blur.rounded()))")
            row("透明度", value: $background.dim, range: AppBackground.dimRange,
                label: "\(Int((background.dim * 100).rounded()))%")
            HStack {
                Button {
                    background.blur = AppBackground.defaultBlur
                    background.dim = AppBackground.defaultDim
                } label: {
                    ChipText(text: "恢复默认", color: Theme.surface, foreground: Theme.text, font: .ui(12, .semibold),
                             hPad: 14, vPad: 6)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { background.closeAdjuster() } label: {
                    ChipText(text: "完成", color: Theme.accent, foreground: Theme.ink, font: .ui(12, .bold), hPad: 18, vPad: 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.line, lineWidth: 1)
        }
        .foregroundStyle(Theme.text)
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.ui(13, .semibold)).frame(width: 48, alignment: .leading)
            Slider(value: value, in: range).tint(Theme.accent)
            ChipText(text: label, color: Theme.surface, foreground: Theme.text, font: .ui(12, .bold).monospacedDigit())
                .frame(width: 52)
        }
    }
}
