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
    private static let file = AppPaths.support.appendingPathComponent("background-image")

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
        if let data = try? Data(contentsOf: Self.file) { image = Self.decode(data) }
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
        self.image = image
    }

    func reset() {
        try? FileManager.default.removeItem(at: Self.file)
        image = nil
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
