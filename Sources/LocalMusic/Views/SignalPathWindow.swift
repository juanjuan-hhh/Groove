import AppKit
import SwiftUI

/// 「音频链路」小窗口：只有一个，点格式标签 / 「输出」标签 / 窗口菜单打开（已经开着就拿到最前面）。
/// 每次打开都放在 Groove 主窗口正中间（主窗口藏起来时放在当前屏幕中间），不记位置；
/// 内容先读好再显示，窗口一出现就是最终大小。之后内容变高变矮时保持上边不动
@MainActor
final class SignalPathWindow: NSObject, NSWindowDelegate {
    static let shared = SignalPathWindow()

    private var panel: NSPanel?
    private var lastFrame: NSRect?

    func show(player: PlayerController) {
        if let panel {
            center(panel)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let view = SignalPathView(initial: SignalPathView.readNow(player))
            .background(Theme.card).environment(player).modifier(ThemedAppearance())
        let host = NSHostingController(rootView: view)
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
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // 先按内容排好版，得到最终大小再摆位置
        host.view.layoutSubtreeIfNeeded()
        panel.setContentSize(host.view.fittingSize)
        self.panel = panel
        center(panel)
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
    }

    /// 放在主窗口正中间，并且整个在那块屏幕的可见区域里
    private func center(_ panel: NSPanel) {
        let main = NSApp.windows.first { !($0 is NSPanel) && $0.isVisible && $0.canBecomeMain }
        let mouse = NSEvent.mouseLocation
        let screen = main?.screen ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let anchor = main?.frame ?? visible
        var frame = panel.frame
        frame.origin = NSPoint(x: anchor.midX - frame.width / 2, y: anchor.midY - frame.height / 2)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        panel.setFrame(frame, display: true)
        lastFrame = frame
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        lastFrame = nil
    }

    func windowDidMove(_ notification: Notification) {
        lastFrame = panel?.frame
    }

    /// 内容变高（比如多了几条原因）时上边保持不动，只往下长；超出屏幕就挪回来
    func windowDidResize(_ notification: Notification) {
        guard let panel, let last = lastFrame else { return }
        var frame = panel.frame
        frame.origin.y = last.maxY - frame.height
        if let visible = panel.screen?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = min(visible.minY, visible.maxY - frame.height)
        }
        lastFrame = frame
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }
}

/// 按 Esc 关掉
private final class EscapablePanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}
