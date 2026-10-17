import AppKit
import QuartzCore

/// 切换深色 / 浅色时主窗口的过渡：先把旧样子拍下来盖在最上面，换好外观后，
/// 新样子像一个圆从窗口正中间扩散出来，直到铺满整个窗口（其实是在旧截图上挖一个越来越大的圆洞）。
@MainActor
enum ThemeReveal {
    private static let duration: CFTimeInterval = 0.6
    private static weak var overlay: NSView?

    /// 换外观的那一下包在这里面；窗口不在屏幕上就直接换，不做动画
    static func perform(_ change: () -> Void) {
        overlay?.removeFromSuperview()
        guard let window = mainWindow, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible),
              let content = window.contentView, content.bounds.width > 0, content.bounds.height > 0,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            change()
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)

        // 毛玻璃那部分拍不进截图（是透明的），截图下面垫一层旧外观的底色，免得新样子提前透出来
        var oldBackground: CGColor?
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            oldBackground = NSColor(Theme.bg).cgColor
        }

        let cover = PassThroughView(frame: content.bounds)
        cover.autoresizingMask = [.width, .height]
        cover.wantsLayer = true
        let layer = cover.layer!
        layer.backgroundColor = oldBackground
        let image = CALayer()
        image.frame = layer.bounds
        image.contents = rep.cgImage
        image.contentsGravity = .resize
        layer.addSublayer(image)
        content.addSubview(cover, positioned: .above, relativeTo: nil)
        overlay = cover

        change()

        // 挖洞的遮罩：整块矩形 + 中间一个圆，奇偶填充，圆里面就透明了
        let bounds = layer.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let endRadius = hypot(bounds.width, bounds.height) / 2 + 2
        func path(_ r: CGFloat) -> CGPath {
            let p = CGMutablePath()
            p.addRect(bounds)
            p.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            return p
        }
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.fillRule = .evenOdd
        mask.path = path(0)
        layer.mask = mask

        // 等 SwiftUI 把新外观画好（下一轮再开始），圆再开始扩散
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard overlay === cover else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                cover.removeFromSuperview()
            }
            let anim = CABasicAnimation(keyPath: "path")
            anim.fromValue = path(0)
            anim.toValue = path(endRadius)
            anim.duration = duration
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mask.path = path(endRadius)
            mask.add(anim, forKey: "reveal")
            CATransaction.commit()
        }
    }

    /// 主窗口（WindowGroup "main"），找不到就用当前的主窗口
    private static var mainWindow: NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) && ($0.identifier?.rawValue.hasPrefix("main") ?? false) }
            ?? NSApp.mainWindow.flatMap { $0 is NSPanel ? nil : $0 }
    }

    /// 盖在上面的截图不挡鼠标
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
