import AppKit
import QuartzCore

/// 切换深色 / 浅色时主窗口的过渡：先把旧样子拍下来盖在最上面，再换外观。
/// 换成浅色：新样子像一个圆从窗口正中间扩散出来，直到铺满（在旧截图上挖一个越来越大的圆洞）；
/// 换成深色反过来：深色从四周往中间包围回来（旧截图只留中间一个越来越小的圆）。
@MainActor
enum ThemeReveal {
    private static let duration: CFTimeInterval = 0.6
    private static weak var overlay: NSView?

    /// 换外观的那一下包在这里面；toDark 是换完后是不是深色。窗口不在屏幕上就直接换，不做动画
    static func perform(toDark: Bool, _ change: () -> Void) {
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

        // 遮罩：换浅色是整块矩形 + 中间一个圆（奇偶填充，圆里透明，圆越来越大）；
        // 换深色只留中间一个圆（圆外透明，圆越来越小）
        let bounds = layer.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let fullRadius = hypot(bounds.width, bounds.height) / 2 + 2
        func path(_ r: CGFloat) -> CGPath {
            let p = CGMutablePath()
            if !toDark { p.addRect(bounds) }
            p.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            return p
        }
        let startPath = path(toDark ? fullRadius : 0)
        let endPath = path(toDark ? 0 : fullRadius)
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.fillRule = .evenOdd
        mask.path = startPath
        layer.mask = mask

        // 等 SwiftUI 把新外观画好（下一轮再开始），圆再开始动
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard overlay === cover else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                cover.removeFromSuperview()
            }
            let anim = CABasicAnimation(keyPath: "path")
            anim.fromValue = startPath
            anim.toValue = endPath
            anim.duration = duration
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mask.path = endPath
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
