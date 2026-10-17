import AppKit
import QuartzCore

/// 切换深色 / 浅色时主窗口的过渡：先把旧样子拍下来盖在最上面，再换外观。
/// 换成浅色：新样子像一个圆从窗口正中间扩散出来，直到铺满（在旧截图上挖一个越来越大的圆洞）；
/// 换成深色反过来：深色从四周往中间包围回来（旧截图只留中间一个越来越小的圆）。
/// 圆的边是柔和渐变的，不是一条硬线。
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

        // 遮罩：一个以窗口中心为圆心的径向渐变，透明的部分透出下面的新样子，
        // 圆的边上留一圈 2×feather 宽的渐变，黑白交界是柔和的而不是一条硬线。
        // 换浅色：圆里透明、圆外留旧截图，圆越来越大；换深色反过来，圆里留旧截图、圆越来越小。
        // 动的是渐变的 locations：边从中心的一个点长出来，再以固定宽度一直走到超出窗口四角
        // （换深色反过来，最后收成一个点），开头结尾都不会突然冒出或剩下一团雾
        let bounds = layer.bounds
        let feather: CGFloat = 28
        let fullRadius = hypot(bounds.width, bounds.height) / 2 + 2
        let outer = fullRadius + feather * 2
        let edge = feather * 2 / outer
        let small: [NSNumber] = [0, NSNumber(value: Double(edge))]
        let large: [NSNumber] = [NSNumber(value: Double(fullRadius / outer)), 1]
        let point: [NSNumber] = [0, 0]
        let steps = toDark ? [large, small, point] : [point, small, large]
        let times: [NSNumber] = toDark ? [0, NSNumber(value: Double(1 - edge)), 1] : [0, NSNumber(value: Double(edge)), 1]
        let mask = CAGradientLayer()
        mask.type = .radial
        mask.frame = bounds
        mask.startPoint = CGPoint(x: 0.5, y: 0.5)
        mask.endPoint = CGPoint(x: 0.5 + outer / bounds.width, y: 0.5 + outer / bounds.height)
        let clear = CGColor(gray: 0, alpha: 0), solid = CGColor(gray: 0, alpha: 1)
        mask.colors = toDark ? [solid, clear] : [clear, solid]
        mask.locations = steps[0]
        layer.mask = mask

        // 等 SwiftUI 把新外观画好（下一轮再开始），圆再开始动
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard overlay === cover else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                cover.removeFromSuperview()
            }
            let anim = CAKeyframeAnimation(keyPath: "locations")
            anim.values = steps
            anim.keyTimes = times
            anim.duration = duration
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mask.locations = steps[2]
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
