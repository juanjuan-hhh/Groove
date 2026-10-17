import SwiftUI

enum LibraryTab: String, CaseIterable, Identifiable {
    case songs = "歌曲"
    case playlists = "歌单"
    case albums = "专辑"
    case artists = "歌手"
    case folders = "文件夹"
    var id: Self { self }
}

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @State private var tab: LibraryTab = .songs
    @State private var searchText = ""
    @State private var newPlaylistName = ""
    /// 正在播放页完全盖住歌曲库时为 true（见下面的 onChange）
    @State private var libraryCovered = false

    var body: some View {
        // 标题栏隐藏后，顶上至少留出红绿灯那一条的高度（系统已经留了就不重复留）
        GeometryReader { geo in
            content.padding(.top, max(0, Self.titleBarHeight - geo.safeAreaInsets.top))
        }
        .foregroundStyle(Theme.text)
        // 毛玻璃底透出一点壁纸，再盖一层半透明的底色
        .background {
            ZStack {
                WindowGlass()
                Theme.bg.opacity(0.72)
            }
            .ignoresSafeArea()
        }
    }

    static let titleBarHeight: CGFloat = 28

    private var content: some View {
        ZStack {
            VStack(spacing: 0) {
                TopBar(tab: $tab, searchText: $searchText, searchActive: !libraryCovered)
                ThemeDivider()
                Group {
                    if library.folders.isEmpty {
                        EmptyLibraryView()
                    } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        SongListView(tracks: library.search(searchText))
                    } else {
                        switch tab {
                        case .songs: SongsTab()
                        case .playlists: PlaylistsView()
                        case .albums: AlbumsView()
                        case .artists: ArtistsView()
                        case .folders: FoldersView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                MiniPlayerBar()
            }

            if let notice = ExclusiveOutput.shared.notice {
                VStack {
                    Spacer()
                    ChipText(text: notice, color: Theme.text, foreground: Theme.onText, font: .ui(12, .semibold), hPad: 14, vPad: 7)
                        .padding(.bottom, 90)
                }
                .transition(.opacity)
                .zIndex(2)
                .allowsHitTesting(false)
            }

            if player.showNowPlaying && player.current != nil {
                NowPlayingView()
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.92), value: player.showNowPlaying)
        // 搜索框是 AppKit 输入框，被正在播放页盖住后鼠标经过还是会变成输入光标（I 形）。
        // 滑入动画结束后把它换成一样的静态文字，收起时马上换回来。
        .onChange(of: player.showNowPlaying) { _, showing in
            guard showing else {
                libraryCovered = false
                return
            }
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                if player.showNowPlaying { libraryCovered = true }
            }
        }
        .sheet(item: Binding(get: { player.searchTarget }, set: { player.searchTarget = $0 })) { track in
            OnlineSearchView(track: track)
                .environment(player)
                .modifier(ThemedAppearance())
        }
        .alert("新建歌单", isPresented: Binding(
            get: { library.playlistDraft != nil },
            set: { if !$0 { library.playlistDraft = nil } }
        )) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") {
                library.createPlaylist(name: newPlaylistName, tracks: library.playlistDraft ?? [])
                newPlaylistName = ""
            }
            Button("取消", role: .cancel) { newPlaylistName = "" }
        }
    }
}

struct TopBar: View {
    @Binding var tab: LibraryTab
    @Binding var searchText: String
    /// false 时搜索框换成静态文字（被正在播放页盖住时）
    var searchActive = true
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @AppStorage(AppSettings.autoFetchKey) private var autoFetch = true
    @AppStorage(AppearanceMode.key) private var appearance: AppearanceMode = .dark
    @AppStorage(SpinningArtwork.enabledKey) private var spinCover = true
    @AppStorage(FloatingLyricsMode.key) private var floatingLyrics: FloatingLyricsMode = .always
    @AppStorage(FloatingLyricsMode.whenTuckedKey) private var lyricsWhenTucked = false

    var body: some View {
        HStack(spacing: 14) {
            // 分段胶囊：选中的是奶油色底 + 深色字（Porthole 网页的语言切换按钮）
            HStack(spacing: 2) {
                ForEach(LibraryTab.allCases) { item in
                    let selected = tab == item && searchText.isEmpty
                    Button {
                        tab = item
                        searchText = ""
                    } label: {
                        Text(item.rawValue)
                            .font(.ui(11, selected ? .bold : .semibold))
                            .foregroundStyle(selected ? Theme.onText : Theme.text2)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(selected ? Theme.text : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Capsule().fill(Theme.card))
            .animation(.easeInOut(duration: 0.15), value: tab)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text2)
                if searchActive {
                    TextField("搜索歌名、歌手、拼音", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.ui(12))
                } else {
                    Text(searchText.isEmpty ? "搜索歌名、歌手、拼音" : searchText)
                        .font(.ui(12))
                        .foregroundStyle(searchText.isEmpty ? Theme.text3 : Theme.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().stroke(searchText.isEmpty ? Theme.line : Theme.accent, lineWidth: 1))
            .frame(width: 200)

            SleepTimerMenu(size: 13)

            AppearanceToggle()

            Menu {
                Button("添加音乐文件夹…") { library.addFolder() }
                Button("重新扫描") { library.rescan() }
                    .disabled(library.folders.isEmpty || library.isScanning)
                if !library.folders.isEmpty {
                    Menu("移除音乐文件夹") {
                        ForEach(library.folders, id: \.self) { folder in
                            Button(folder) { library.removeFolder(folder) }
                        }
                    }
                }
                Divider()
                OutputMenuItems()
                Divider()
                Toggle("自动联网获取缺少的封面和歌词", isOn: $autoFetch)
                Toggle("播放时旋转封面", isOn: $spinCover)
                Button("悬浮球大小…") { FloatingBall.shared.showSizeAdjuster(player: player) }
                Picker("悬浮球歌词", selection: $floatingLyrics) {
                    ForEach(FloatingLyricsMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("贴边时也显示歌词", isOn: $lyricsWhenTucked)
                    .disabled(floatingLyrics == .off)
                Picker("外观", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("设置")

            // 最右边：切到悬浮球（正在播放页也在右上角放了一个）
            IconButton(systemName: "circle.circle", size: 13, help: "切换到悬浮球（⇧⌘M）") {
                FloatingBall.shared.enter(player: player)
            }
            .foregroundStyle(Theme.accent)
            .frame(width: 22, height: 22)
            .disabled(player.current == nil).opacity(player.current == nil ? 0.4 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
        .background(WindowDragArea())
    }
}

/// 设置菜单里的「输出设备」和「独占输出」
private struct OutputMenuItems: View {
    private var output: ExclusiveOutput { ExclusiveOutput.shared }

    var body: some View {
        Picker("输出设备", selection: Binding(get: { output.selectedUID }, set: { output.select($0) })) {
            Text("跟随系统").tag("")
            ForEach(output.devices) { Text($0.name).tag($0.uid) }
        }
        Toggle("独占输出（外接解码器用）", isOn: Binding(get: { output.enabled }, set: { output.setEnabled($0) }))
        // 不独占时 DSD 一律转成 PCM（DoP 经过系统混音会变成噪音）
        Picker("DSD 输出方式", selection: Binding(get: { output.dsdMode }, set: { output.setDSDMode($0) })) {
            ForEach(DSDOutputMode.allCases) { Text($0.label).tag($0) }
        }
        .disabled(!output.enabled)
    }
}

/// 顶栏的深色 / 浅色切换按钮（在定时和设置中间）。跟随系统时点一下切到和现在相反的那种
private struct AppearanceToggle: View {
    @AppStorage(AppearanceMode.key) private var mode: AppearanceMode = .dark
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                mode = scheme == .dark ? .light : .dark
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(scheme == .dark ? "切换到浅色" : "切换到深色")
    }

    private var icon: String {
        switch mode {
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }
}

struct EmptyLibraryView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house")
                .font(.system(size: 56))
                .foregroundStyle(Theme.text3)
            Text("还没有添加音乐").font(.ui(22, .bold))
            Text("选择存放音乐的文件夹，会自动扫描里面所有的歌曲（包括子文件夹）。")
                .font(.ui(14))
                .foregroundStyle(Theme.text2)
            Button { library.addFolder() } label: {
                Text("添加音乐文件夹")
                    .font(.ui(15, .bold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(40)
    }
}
