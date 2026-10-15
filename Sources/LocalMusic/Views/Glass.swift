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
/// （Finder、「应用程序」里显示的仍是打包进去的黑底图标，App 运行时程序坞才会变。）
@MainActor
enum DockIcon {
    private static let lightImage: NSImage? = Bundle.main.url(forResource: "AppIcon-light", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    static func update(for appearance: NSAppearance) {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSApp.applicationIconImage = isDark ? nil : lightImage
    }
}
