import AppKit
import ScreenCaptureKit

/// 「读取屏幕颜色」：用屏幕录制权限截一小块屏幕（不带 Groove 自己的悬浮窗），算出那块有多亮。
/// 刘海歌词胶囊、贴边藏一半的球都用它决定配深色还是浅色；没开、没权限、截不到时返回 nil，调用方按原来的办法猜
enum ScreenColorSampler {
    static let enabledKey = "floatingBallScreenColor"
    /// 已经自动向系统要过一次权限（之后只在菜单里点它时再要）
    static let askedKey = "floatingBallScreenColorAsked"
    /// 默认开着：有权限就直接用，没权限也不会弹任何东西（只有在菜单里点它时才向系统要权限）
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    /// 菜单里的开关。打开时没有权限就向系统要，要不到就弹一张卡片说去哪里打开
    @MainActor
    static func toggle() {
        // 菜单里打勾 = 开着并且有权限；开着但没权限时点它是去要权限，不是关掉
        if enabled && granted {
            UserDefaults.standard.set(false, forKey: enabledKey)
            return
        }
        UserDefaults.standard.set(true, forKey: enabledKey)
        requestIfNeeded()
    }

    /// 没有权限就向系统要，要不到就弹卡片说去哪里打开
    @MainActor
    static func requestIfNeeded() {
        guard !granted else { return }
        // 第一次会弹系统的授权框；已经拒绝过就什么也不弹，直接返回 false
        if !CGRequestScreenCaptureAccess() {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "需要「屏幕录制」权限"
            alert.informativeText = "打开「系统设置 → 隐私与安全性 → 屏幕与系统录音」，把 Groove 打开，然后退出 Groove 再打开一次。\n\n只用来看歌词胶囊和贴边小球后面那一小块是深色还是浅色，不会录下或保存任何画面。没打开之前还是按原来的办法判断。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "好")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 屏幕、窗口列表查一次不便宜，记一分钟再查（Groove 自己的悬浮窗不管露没露出来都在里面，排除它们用）；
    /// 截图出错、找不到屏幕时清掉重查
    @MainActor private static var cachedContent: (content: SCShareableContent, time: Date)?

    @MainActor
    private static func shareableContent() async throws -> SCShareableContent {
        if let cached = cachedContent, Date().timeIntervalSince(cached.time) < 60 { return cached.content }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        cachedContent = (content, Date())
        return content
    }

    /// 屏幕关着、锁屏时不截（截了也没用）
    static var screenAvailable: Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return false }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           (session["CGSSessionScreenIsLocked"] as? Bool) == true { return false }
        return true
    }

    /// 屏幕上这块区域（全局坐标）的平均亮度 0...1，不算 excluding 里的窗口（Groove 自己的悬浮窗）
    @MainActor
    static func luminance(of rect: NSRect, excluding windowNumbers: [Int]) async -> Double? {
        guard enabled, granted,
              // 贴右边藏一半时球的中心正好压在屏幕右边线上，按中心点找屏幕会找不到，所以按重叠面积最大的那块屏幕算
              let screen = NSScreen.screens.max(by: { area(rect.intersection($0.frame)) < area(rect.intersection($1.frame)) }),
              area(rect.intersection(screen.frame)) > 0,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        let area = rect.intersection(screen.frame)
        guard area.width >= 1, area.height >= 1 else { return nil }
        // 截图用的坐标：这块屏幕的左上角是原点，往下是正
        let source = CGRect(x: area.minX - screen.frame.minX, y: screen.frame.maxY - area.maxY,
                            width: area.width, height: area.height)
        let excluded = Set(windowNumbers.map { CGWindowID($0) })
        do {
            let content = try await shareableContent()
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                cachedContent = nil
                return nil
            }
            let mine = content.windows.filter { excluded.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: mine)
            let config = SCStreamConfiguration()
            config.sourceRect = source
            // 输出尺寸要和截的那块一样的长宽比，不然多出来的地方是黑边，算出来会偏暗；最长边缩到 24 像素就够算亮度了
            let shrink = min(1, 24 / max(source.width, source.height))
            config.width = max(1, Int((source.width * shrink).rounded()))
            config.height = max(1, Int((source.height * shrink).rounded()))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return averageLuminance(image)
        } catch {
            cachedContent = nil
            return nil
        }
    }

    private static func area(_ r: NSRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// 缩成 1 个像素取颜色，按人眼对红绿蓝的敏感程度算亮度
    private static func averageLuminance(_ image: CGImage) -> Double? {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / 255
    }
}
