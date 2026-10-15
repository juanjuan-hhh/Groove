import AppKit

/// 双击顶栏：窗口铺满屏幕可用区域（菜单栏以下、程序坞以外），再双击恢复原来的大小和位置。
/// 不是绿色按钮那种全屏（不会单独占一个桌面）。
@MainActor
enum WindowFill {
    private static var savedFrames: [ObjectIdentifier: NSRect] = [:]

    /// 按系统设置「连按窗口标题栏以…」：设为最小化就最小化，否则铺满 / 恢复
    static func handleDoubleClick(_ window: NSWindow) {
        if UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") == "Minimize" {
            window.performMiniaturize(nil)
        } else {
            toggle(window)
        }
    }

    static func toggle(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let target = screen.visibleFrame
        let key = ObjectIdentifier(window)
        if isFilled(window.frame, target), let saved = savedFrames[key] {
            savedFrames[key] = nil
            window.setFrame(saved, display: true, animate: true)
        } else {
            savedFrames[key] = window.frame
            window.setFrame(target, display: true, animate: true)
        }
    }

    private static func isFilled(_ frame: NSRect, _ target: NSRect) -> Bool {
        abs(frame.minX - target.minX) < 2 && abs(frame.minY - target.minY) < 2
            && abs(frame.width - target.width) < 2 && abs(frame.height - target.height) < 2
    }
}
