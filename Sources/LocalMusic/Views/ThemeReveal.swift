import AppKit
import QuartzCore

/// 切换深色 / 浅色时主窗口的过渡：先把旧样子拍下来盖在最上面，再换外观。
/// 换成浅色：新样子像一个圆从窗口正中间扩散出来，直到铺满（在旧截图上挖一个越来越大的圆洞）；
/// 换成深色反过来：深色从四周往中间包围回来（旧截图只留中间一个越来越小的圆）。
/// 圆的边是柔和渐变的，不是一条硬线。
@MainActor
enum ThemeReveal {
    private static let duration: CFTimeInterval = 0.6
    private static weak var overlay: CALayer?

    /// 换外观的那一下包在这里面；toDark 是换完后是不是深色。窗口不在屏幕上就直接换，不做动画
    static func perform(toDark: Bool, _ change: () -> Void) {
        overlay?.removeFromSuperlayer()
        guard let window = mainWindow, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible),
              let content = window.contentView,
              // 盖在整个窗口的最外层（连红绿灯一起），不放进 SwiftUI 的视图里
              let frameView = Optional(content.superview ?? content), let host = frameView.layer,
              let snapshot = snapshot(of: window), snapshot.width > 1 else {
            change()
            applyAppKitAppearance()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)   // 不要系统默认的淡入，一放上去就完全盖住
        let layer = CALayer()
        layer.frame = host.bounds
        layer.zPosition = 10_000
        let image = CALayer()
        image.frame = layer.bounds
        image.contents = snapshot
        image.contentsGravity = .resize
        layer.addSublayer(image)
        host.addSublayer(layer)
        overlay = layer
        CATransaction.commit()

        change()
        // 菜单、毛玻璃这些 AppKit 部分也马上换（原来要等 SwiftUI 下一轮才换，正好撞上动画，会卡一下）
        applyAppKitAppearance()

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

        DispatchQueue.main.async {
            guard overlay === layer else { return }
            // 先把新外观整个画完（被截图盖着看不见），再开始动画——重活不和动画抢同一段时间
            frameView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.removeFromSuperlayer()
                CATransaction.commit()
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

    /// 把窗口现在的样子拍成一张图（和屏幕上一模一样，包括透出来的壁纸）。
    /// cacheDisplay、layer.render 都拍不到 SwiftUI 列表里的东西，只能找窗口服务器要。
    /// CGWindowListCreateImage 在新 SDK 里标成了不能直接调，运行时还在，拍自己的窗口不用权限
    private static func snapshot(of window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard window.windowNumber > 0,
              let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(sym, to: Capture.self)
        // .optionIncludingWindow = 8；.boundsIgnoreFraming = 1 | .bestResolution = 8
        return capture(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue()
    }

    private static func applyAppKitAppearance() {
        NSApp.appearance = AppearanceMode.current.nsAppearance
    }

}
