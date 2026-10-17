import AppKit
import SwiftUI

/// 「音频链路」小窗口：只有一个，点格式标签 / 「输出」标签 / 窗口菜单打开（已经开着就拿到最前面）。
/// 大小跟着内容走，位置会记住，但总是放在屏幕可见区域里（不压在程序坞下面）
@MainActor
final class SignalPathWindow: NSObject, NSWindowDelegate {
    static let shared = SignalPathWindow()

    private var panel: NSPanel?

    func show(player: PlayerController) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SignalPathView().background(Theme.card).environment(player).modifier(ThemedAppearance()))
        host.sizingOptions = .preferredContentSize
        let panel = EscapablePanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.title = "音频链路"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(Theme.card)
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // 先按主窗口所在屏幕居中，再读上次记住的位置
        if let screen = (NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) })?.screen ?? NSScreen.main {
            let size = host.view.fittingSize
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        panel.setFrameAutosaveName("SignalPathWindow")
        self.panel = panel
        keepOnScreen()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }

    /// 内容变高（比如多了几条原因）后窗口也变高：超出屏幕可见区域就挪回来
    func windowDidResize(_ notification: Notification) { keepOnScreen() }

    private func keepOnScreen() {
        guard let panel, let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        if frame.height > visible.height { frame.origin.y = visible.maxY - frame.height }
        else { frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height) }
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }
}

/// 按 Esc 关掉
private final class EscapablePanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}
