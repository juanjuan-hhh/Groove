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

/// 程序坞图标跟着 App 的外观变：浅色时用白底图标，深色时用默认的黑底图标。
/// 记住上次用的是哪个，下次启动一开始就用它；同时把 App 本身的图标也换掉，
/// 这样 App 没开时程序坞里固定的图标、启动时跳动的图标也是上次的颜色。
@MainActor
enum DockIcon {
    private static let lightImage: NSImage? = Bundle.main.url(forResource: "AppIcon-light", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
    private static let savedKey = "dockIconIsLight"
    /// 这次运行里已经给 App 本身设成了哪个（nil = 还没设过）
    private static var bundleIconIsLight: Bool?

    /// 启动时尽早调用：先按上次退出时的颜色显示
    static func applySaved() {
        if UserDefaults.standard.bool(forKey: savedKey), let lightImage {
            NSApp.applicationIconImage = lightImage
        }
    }

    static func update(for appearance: NSAppearance) {
        let isLight = appearance.bestMatch(from: [.darkAqua, .aqua]) != .darkAqua && lightImage != nil
        NSApp.applicationIconImage = isLight ? lightImage : nil
        UserDefaults.standard.set(isLight, forKey: savedKey)
        setBundleIcon(isLight: isLight)
    }

    /// 换 App 本身的图标（Finder、程序坞里没打开时显示的）。没权限就算了。
    private static func setBundleIcon(isLight: Bool) {
        guard bundleIconIsLight != isLight else { return }
        bundleIconIsLight = isLight
        NSWorkspace.shared.setIcon(isLight ? lightImage : nil, forFile: Bundle.main.bundlePath, options: [])
    }
}
