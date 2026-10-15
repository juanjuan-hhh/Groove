import SwiftUI

enum LibraryTab: String, CaseIterable, Identifiable {
    case songs = "歌曲"
    case playlists = "列表"
    case albums = "专辑"
    case artists = "艺术家"
    case folders = "文件夹"
    var id: Self { self }
}

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @State private var tab: LibraryTab = .songs
    @State private var searchText = ""
    @State private var newPlaylistName = ""

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TopBar(tab: $tab, searchText: $searchText)
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

            if player.showNowPlaying && player.current != nil {
                NowPlayingView()
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: player.showNowPlaying)
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .toolbarBackground(Theme.bg, for: .windowToolbar)
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
    @Environment(LibraryStore.self) private var library
    @AppStorage(AppSettings.autoFetchKey) private var autoFetch = true

    var body: some View {
        HStack(spacing: 18) {
            // 分段胶囊：选中的是奶油色底 + 深色字（Porthole 网页的语言切换按钮）
            HStack(spacing: 4) {
                ForEach(LibraryTab.allCases) { item in
                    let selected = tab == item && searchText.isEmpty
                    Button {
                        tab = item
                        searchText = ""
                    } label: {
                        Text(item.rawValue)
                            .font(.ui(14, selected ? .bold : .semibold))
                            .foregroundStyle(selected ? Theme.ink : Theme.text2)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(selected ? Theme.text : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Capsule().fill(Theme.card))
            .animation(.easeInOut(duration: 0.15), value: tab)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.text2)
                TextField("搜索歌名、歌手、拼音", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.ui(13))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().stroke(searchText.isEmpty ? Theme.line : Theme.accent, lineWidth: 1))
            .frame(width: 230)

            SleepTimerMenu()

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
                Toggle("自动联网获取缺少的封面和歌词", isOn: $autoFetch)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 16))
                    .foregroundStyle(Theme.text2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("设置")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
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
