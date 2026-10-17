import AppKit
import SwiftUI

/// 打开「独占输出」时在主窗口正中弹的小卡片：独占时 App 音量固定 100%，提醒先看一下设备音量。
/// 勾了「不再提示」以后就不再弹
@MainActor
enum ExclusiveVolumeWarning {
    static let dismissedKey = "exclusiveVolumeWarningDismissed"
    private static var panel: NSPanel?

    static func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: dismissedKey) else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        let main = NSApp.windows.first { !($0 is NSPanel) && $0.isVisible && $0.canBecomeMain }
        let area = main?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.midY - panel.frame.height / 2))
        panel.orderFrontRegardless()
    }

    fileprivate static func close(dontShowAgain: Bool) {
        if dontShowAgain { UserDefaults.standard.set(true, forKey: dismissedKey) }
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WarningCard().modifier(ThemedAppearance()))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        return panel
    }
}

private struct WarningCard: View {
    @State private var dontShowAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.accent.opacity(0.15)))
                VStack(alignment: .leading, spacing: 6) {
                    Text("开启独占后请注意设备音量！").font(.ui(15, .bold))
                    Text("独占时 Groove 以 100% 音量直接输出，请先把解码器或耳机的音量调低。")
                        .font(.ui(12)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Toggle("不再提示", isOn: $dontShowAgain)
                    .toggleStyle(.checkbox)
                    .font(.ui(12, .semibold))
                    .foregroundStyle(Theme.text2)
                Spacer()
                Button { ExclusiveVolumeWarning.close(dontShowAgain: dontShowAgain) } label: {
                    ChipText(text: "知道了", color: Theme.accent, foreground: Theme.ink, font: .ui(12, .bold), hPad: 18, vPad: 6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.line, lineWidth: 1)
        }
        .foregroundStyle(Theme.text)
    }
}

/// 主窗口正中的一张简单提示卡片：标题（+ 可选的一行说明）+ 「知道了」（和独占提示卡片一个样子）
@MainActor
enum InfoCard {
    private static var panel: NSPanel?

    static func show(icon: String, title: String, message: String? = nil) {
        panel?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 140),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: InfoCardView(icon: icon, title: title, message: message)
            .modifier(ThemedAppearance()))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        self.panel = panel
        let main = NSApp.windows.first { !($0 is NSPanel) && $0.isVisible && $0.canBecomeMain }
        let area = main?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.midY - panel.frame.height / 2))
        panel.orderFrontRegardless()
    }

    fileprivate static func close() {
        panel?.orderOut(nil)
    }
}

private struct InfoCardView: View {
    let icon: String
    let title: String
    let message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: message == nil ? .center : .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.accent.opacity(0.15)))
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.ui(15, .bold))
                    if let message {
                        Text(message)
                            .font(.ui(12)).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button { InfoCard.close() } label: {
                    ChipText(text: "知道了", color: Theme.accent, foreground: Theme.ink, font: .ui(12, .bold), hPad: 18, vPad: 6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.line, lineWidth: 1)
        }
        .foregroundStyle(Theme.text)
    }
}

/// 主窗口正中的半透明小提示（如「导入成功」）：淡入，停 2 秒，淡出；不接鼠标，不挡操作
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, icon: String = "checkmark.circle.fill", seconds: Double = 2) {
        hideTask?.cancel()
        panel?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ToastView(text: text, icon: icon).modifier(ThemedAppearance()))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        self.panel = panel
        let main = NSApp.windows.first { !($0 is NSPanel) && $0.isVisible && $0.canBecomeMain }
        let area = main?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.midY - panel.frame.height / 2))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; panel.animator().alphaValue = 0 } completionHandler: {
                MainActor.assumeIsolated { if Toast.panel === panel { panel.orderOut(nil) } }
            }
        }
    }
}

private struct ToastView: View {
    let text: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(text).font(.ui(14, .bold)).foregroundStyle(Theme.text)
        }
        .fixedSize()
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background {
            ZStack {
                GlassBackground(cornerRadius: 22)
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card.opacity(0.55))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.line.opacity(0.6), lineWidth: 1))
    }
}
