import AppKit
import SwiftUI

@main
struct LocalMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = LibraryStore()
    @State private var player = PlayerController()

    var body: some Scene {
        WindowGroup("Groove") {
            ContentView()
                .environment(library)
                .environment(player)
                .frame(minWidth: 720, minHeight: 560)
                .modifier(ThemedAppearance())
                .tint(Theme.accent)
                .onAppear { appDelegate.player = player }
        }
        .defaultSize(width: 980, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加音乐文件夹…") { library.addFolder() }
                    .keyboardShortcut("o")
                Button("重新扫描音乐库") { library.rescan() }
                    .keyboardShortcut("r")
                    .disabled(library.folders.isEmpty)
            }
            CommandMenu("播放") {
                Button("播放 / 暂停（空格）") { player.togglePlayPause() }
                Button("下一首") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("上一首") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("快进 10 秒") { player.skip(by: 10) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("快退 10 秒") { player.skip(by: -10) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Divider()
                Button("随机播放：\(player.shuffle ? "开" : "关")") { player.toggleShuffle() }
                Button("循环模式：\(player.repeatMode.label)") { player.cycleRepeat() }
                Divider()
                LyricOffsetMenuItems(showShortcuts: true).environment(player)
                Divider()
                Button(player.showNowPlaying ? "返回歌曲列表" : "打开正在播放") {
                    player.showNowPlaying.toggle()
                }
                .keyboardShortcut("l")
                .disabled(player.current == nil)
                Button("切换到悬浮球 / 返回主窗口") { FloatingBall.shared.toggle(player: player) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(player.current == nil)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var player: PlayerController?
    private var keyMonitor: Any?
    private var titleBarMonitor: Any?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // 按「外观」设置（默认深色，和 Porthole 一样）：菜单、弹窗、播放队列浮窗也跟着变
        NSApp.appearance = AppearanceMode.current.nsAppearance
        // 浅色外观时程序坞图标换成白底的
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { app, _ in
            MainActor.assumeIsolated { DockIcon.update(for: app.effectiveAppearance) }
        }
        NSApp.activate(ignoringOtherApps: true)

        // 空格键播放/暂停（在搜索框里打字时不拦截）
        // 双击最上面的标题栏也是铺满 / 恢复，而不是系统默认的缩放
        titleBarMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2, let window = event.window,
                  window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen),
                  event.locationInWindow.y > window.contentLayoutRect.maxY else { return event }
            MainActor.assumeIsolated { WindowFill.handleDoubleClick(window) }
            return nil
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 49, modifiers.subtracting([.capsLock, .numericPad, .function]).isEmpty else { return event }
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            MainActor.assumeIsolated { self?.player?.togglePlayPause() }
            return nil
        }
    }

    // 关掉窗口后音乐继续播放，点 Dock 图标可以重新打开窗口
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // 悬浮球模式下点 Dock 图标：回到主窗口
    // 点程序坞图标：
    // 悬浮球模式 → 回到主窗口；窗口被「−」收进程序坞 → 放出来；窗口被藏起来了 → 显示出来；
    // 窗口已经关掉了 → 交给系统新开一个
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if FloatingBall.shared.isShown {
            FloatingBall.shared.exit()
            return false
        }
        let mainWindows = NSApp.windows.filter { !($0 is NSPanel) && $0.canBecomeMain }
        if let minimized = mainWindows.first(where: \.isMiniaturized) {
            minimized.deminiaturize(nil)
            minimized.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return false
        }
        if !flag, let hidden = mainWindows.first {
            hidden.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return false
        }
        return true
    }
}
