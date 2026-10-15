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
                Divider()
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
        HStack(spacing: 26) {
            ForEach(LibraryTab.allCases) { item in
                Button {
                    tab = item
                    searchText = ""
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 16, weight: tab == item && searchText.isEmpty ? .bold : .regular))
                        .foregroundStyle(tab == item && searchText.isEmpty ? Color.primary : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索歌名、歌手、拼音", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .frame(width: 220)

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
                .foregroundStyle(.secondary)
            Text("还没有添加音乐").font(.title2.weight(.semibold))
            Text("选择存放音乐的文件夹，会自动扫描里面所有的歌曲（包括子文件夹）。")
                .foregroundStyle(.secondary)
            Button("添加音乐文件夹") { library.addFolder() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
    }
}
