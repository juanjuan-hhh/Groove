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
                .preferredColorScheme(.dark)
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
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var player: PlayerController?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // 和 Porthole 一样只用深色：菜单、弹窗、播放队列浮窗也都是深色
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)

        // 空格键播放/暂停（在搜索框里打字时不拦截）
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
}
