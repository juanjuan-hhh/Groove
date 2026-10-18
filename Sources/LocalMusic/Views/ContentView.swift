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
    @Environment(\.colorScheme) private var colorScheme
    /// 底部播放条的高度（它浮在列表上面，列表底下要让出这么多）
    @State private var miniBarHeight: CGFloat = 72

    var body: some View {
        // 标题栏隐藏后，顶上至少留出红绿灯那一条的高度（系统已经留了就不重复留）
        GeometryReader { geo in
            content.padding(.top, max(0, Self.titleBarHeight - geo.safeAreaInsets.top))
        }
        .foregroundStyle(Theme.text)
        // 毛玻璃底透出一点壁纸，再盖一层半透明的底色；选了背景图时换成背景图（稍微模糊、压暗，文字照样看得清）
        .background {
            ZStack {
                if let image = AppBackground.shared.image {
                    Theme.bg
                    GeometryReader { geo in
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: AppBackground.shared.blur, opaque: true)
                            .clipped()
                    }
                    // 盖一层底色：按图片从上到下每一处的亮度，至少压到字看得清（见 AppBackground.scrimLevels）
                    let levels = AppBackground.shared.scrimLevels(dark: colorScheme == .dark)
                    LinearGradient(stops: levels.enumerated().map { i, level in
                        Gradient.Stop(color: Theme.bg.opacity(level),
                                      location: levels.count == 1 ? 0 : CGFloat(i) / CGFloat(levels.count - 1))
                    }, startPoint: .top, endPoint: .bottom)
                } else {
                    WindowGlass()
                    Theme.bg.opacity(0.72)
                }
            }
            .ignoresSafeArea()
        }
    }

    static let titleBarHeight: CGFloat = 28

    private var content: some View {
        ZStack {
            VStack(spacing: 0) {
                TopBar(tab: $tab, searchText: $searchText, searchActive: !libraryCovered)
                Group {
                    if library.folders.isEmpty {
                        EmptyLibraryView().padding(.bottom, miniBarHeight)
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
                // 底栏浮在列表上面（玻璃底），列表能滚到它下面、隐约透出来；
                // 每个列表最底下多留出底栏那么高，滚到底时最后一行不会被挡住
                .contentMargins(.bottom, miniBarHeight, for: .scrollContent)
                .environment(\.miniBarHeight, miniBarHeight)
                .overlay(alignment: .bottom) {
                    MiniPlayerBar()
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { miniBarHeight = $0 }
                }
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
                    // 从底部播放条「长」出来：露出来的范围从播放条那么高、圆角，一路撑满整个窗口；收起时反过来
                    .transition(.modifier(active: ExpandFromBar(progress: 0), identity: ExpandFromBar(progress: 1)))
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: player.showNowPlaying)
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
    @AppStorage(FloatingBall.alwaysKey) private var ballAlwaysOn = false

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
                        .foregroundStyle(searchText.isEmpty ? Theme.faint : Theme.text)
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
            .overlay(Capsule().stroke(searchText.isEmpty ? Theme.divider : Theme.accent, lineWidth: 1))
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
                // 悬浮球的其他设置在悬浮球上点右键
                Toggle("一直显示悬浮球", isOn: Binding(get: { ballAlwaysOn },
                                                    set: { FloatingBall.shared.setAlwaysOn($0, player: player) }))
                Menu("自定义背景图片") {
                    Button("选择图片…") { AppBackground.shared.choose() }
                    Button("调整模糊和透明度…") { AppBackground.shared.showAdjuster() }
                        .disabled(AppBackground.shared.image == nil)
                    Button("恢复默认") { AppBackground.shared.reset() }
                        .disabled(AppBackground.shared.image == nil)
                }
                // 换外观时有圆形过渡：浅色从中间扩散开，深色从四周包围回来（见 ThemeReveal）
                Picker("外观", selection: Binding(get: { appearance }, set: { newValue in
                    guard newValue != appearance else { return }
                    ThemeReveal.perform(toDark: newValue.isDark) { appearance = newValue }
                })) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                // 打开版本信息卡片，里面可以检查更新
                Button("当前版本 \(AppUpdate.version)") { UpdateCards.showAbout() }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .iconBacking(27)
            .help("设置")

            // 最右边：打开 / 关闭悬浮球（正在播放页也在右上角放了一个）
            BallToggleButton(size: 13)
                .frame(width: 22, height: 22)
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
        Toggle("独占输出", isOn: Binding(get: { output.enabled }, set: { on in
            output.setEnabled(on)
            if on { ExclusiveVolumeWarning.showIfNeeded() }
        }))
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
            let next: AppearanceMode = scheme == .dark ? .light : .dark
            ThemeReveal.perform(toDark: next.isDark) { mode = next }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .iconBacking(27)
        // 换外观的圆形过渡从这个按钮扩散出去 / 收回来
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { ThemeReveal.originRect = $0 }
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
                .foregroundStyle(Theme.faint)
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

/// 正在播放页展开 / 收起的过渡：progress 0 = 只有底部播放条那么大，1 = 整个窗口
private struct ExpandFromBar: ViewModifier, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// 底部播放条大概的高度
    private let barHeight: CGFloat = 72

    func body(content: Content) -> some View {
        let p = CGFloat(max(0, min(1, progress)))
        content
            // 页面本身跟着外框一起长大 / 缩小（不另外垫一层底色，那层底色在浅色外观下就是一块白），
            // 只在最后快缩成播放条时才淡掉
            .opacity(Double(min(1, p * 3)))
            .scaleEffect(0.94 + 0.06 * p, anchor: .bottom)
            .mask {
                GeometryReader { geo in
                    let h = barHeight + (geo.size.height - barHeight) * p
                    RoundedRectangle(cornerRadius: Theme.cardRadius * (1 - p), style: .continuous)
                        .frame(width: geo.size.width, height: h)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .ignoresSafeArea()
            }
    }
}
