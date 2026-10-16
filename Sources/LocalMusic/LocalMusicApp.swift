import AppKit
import SwiftUI

@main
struct LocalMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = LibraryStore()
    @State private var player = PlayerController()

    var body: some Scene {
        WindowGroup("Groove", id: "main") {
            ContentView()
                .environment(library)
                .environment(player)
                .frame(minWidth: 720, minHeight: 560)
                .modifier(ThemedAppearance())
                .tint(Theme.accent)
                .onAppear { appDelegate.player = player }
                .background(OpenWindowCapture(delegate: appDelegate))
        }
        .defaultSize(width: 980, height: 740)
        // 隐藏标题栏：背景（正在播放页的模糊封面色）一直铺到窗口最上面，红绿灯浮在上面
        .windowStyle(.hiddenTitleBar)
        .commands {
            // 「窗口」菜单：随时把主窗口叫出来（收起了、关掉了、在悬浮球模式都行）
            CommandGroup(after: .windowArrangement) {
                Button("Groove 主窗口") { appDelegate.showMainWindow() }
                    .keyboardShortcut("0")
            }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // 按「外观」设置（默认深色，和 Porthole 一样）：菜单、弹窗、播放队列浮窗也跟着变
        NSApp.appearance = AppearanceMode.current.nsAppearance
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

    // 退出时把独占的输出设备还给系统、恢复原来的采样率
    func applicationWillTerminate(_ notification: Notification) {
        ExclusiveOutput.shared.release()
    }

    // 关掉窗口后音乐继续播放，点 Dock 图标可以重新打开窗口
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // 悬浮球模式下点 Dock 图标：回到主窗口
    /// 用 SwiftUI 打开一个新的主窗口（主窗口被关掉时用；由 OpenWindowCapture 设好）
    var openMainWindow: (() -> Void)?

    // 点程序坞图标：统一交给 showMainWindow
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    /// 把主窗口叫出来：悬浮球模式 → 回主窗口；被「−」收进程序坞 → 放出来；藏起来了 → 显示；关掉了 → 新开一个
    func showMainWindow() {
        if FloatingBall.shared.isShown {
            FloatingBall.shared.exit()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        // 收起的窗口 canBecomeMain 是 false，所以单独找
        let windows = NSApp.windows.filter { !($0 is NSPanel) && ($0.canBecomeMain || $0.isMiniaturized) }
        if let minimized = windows.first(where: \.isMiniaturized) {
            minimized.deminiaturize(nil)
            minimized.makeKeyAndOrderFront(nil)
        } else if let window = windows.first {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }}


/// 记下 SwiftUI 的「打开窗口」动作，主窗口被关掉后点程序坞图标时用它新开一个
private struct OpenWindowCapture: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let open = openWindow
                delegate.openMainWindow = { open(id: "main") }
            }
    }
}
