import SwiftUI

// MARK: 专辑

struct AlbumsView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 22)], spacing: 26) {
                    ForEach(library.albums) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(track: album.tracks.first, size: 150, cornerRadius: 14)
                                Text(album.name).font(.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                Text("\(album.subtitle) · \(album.tracks.count) 首")
                                    .font(.ui(11))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 150)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
            }
            .navigationDestination(for: TrackGroup.self) { GroupDetailView(group: $0) }
        }
    }
}

// MARK: 艺术家

struct ArtistsView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(library.artists) { artist in
                        NavigationLink(value: artist) {
                            GroupRow(title: artist.name, subtitle: artist.subtitle) {
                                ArtworkView(track: artist.tracks.first, size: 46, circle: true)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationDestination(for: TrackGroup.self) { GroupDetailView(group: $0, circle: true) }
        }
    }
}

// MARK: 文件夹

struct FoldersView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(library.folderGroups) { folder in
                        NavigationLink(value: folder) {
                            GroupRow(title: folder.name, subtitle: "\(folder.tracks.count) 首歌曲 · \(folder.subtitle)") {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Theme.ink)
                                    .frame(width: 46, height: 46)
                                    .background(RoundedRectangle(cornerRadius: Theme.artRadius, style: .continuous).fill(Theme.mustard))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationDestination(for: TrackGroup.self) { GroupDetailView(group: $0) }
        }
    }
}

struct GroupDetailView: View {
    let group: TrackGroup
    var circle = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ArtworkView(track: group.tracks.first, size: 96, cornerRadius: 14, circle: circle)
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.name).font(.ui(22, .bold)).foregroundStyle(Theme.text).lineLimit(2)
                    Text(group.subtitle).font(.ui(13)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(24)
            SongListView(tracks: group.tracks)
        }
        .navigationTitle(group.name)
    }
}

// MARK: 歌单

enum PlaylistRoute: Hashable {
    case favorites
    case playlist(UUID)
}

struct PlaylistsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var renaming: Playlist?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    NavigationLink(value: PlaylistRoute.favorites) {
                        GroupRow(title: "我的收藏", subtitle: "\(library.favorites.count) 首歌曲") {
                            iconTile("heart.fill", Theme.terra, Theme.ink)
                        }
                    }
                    .buttonStyle(.plain)

                    ForEach(library.playlists) { playlist in
                        NavigationLink(value: PlaylistRoute.playlist(playlist.id)) {
                            GroupRow(title: playlist.name, subtitle: "\(playlist.paths.count) 首歌曲") {
                                if let first = library.tracks(in: playlist).first {
                                    ArtworkView(track: first, size: 46)
                                } else {
                                    iconTile("music.note.list", Theme.slate, Theme.cream)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("重命名…") {
                                newName = playlist.name
                                renaming = playlist
                            }
                            Button("删除歌单", role: .destructive) { library.deletePlaylist(playlist.id) }
                        }
                    }

                    Button {
                        library.playlistDraft = []
                    } label: {
                        Label("新建歌单", systemImage: "plus")
                            .font(.ui(14, .bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                }
                .padding(.vertical, 8)
            }
            .navigationDestination(for: PlaylistRoute.self) { route in
                switch route {
                case .favorites:
                    PlaylistDetailView(title: "我的收藏", tracks: library.favoriteTracks, playlistID: nil)
                case .playlist(let id):
                    if let playlist = library.playlist(id) {
                        PlaylistDetailView(title: playlist.name, tracks: library.tracks(in: playlist), playlistID: id)
                    } else {
                        Text("歌单已删除").foregroundStyle(Theme.secondary)
                    }
                }
            }
            .alert("重命名歌单", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("歌单名称", text: $newName)
                Button("确定") {
                    if let renaming { library.renamePlaylist(renaming.id, to: newName) }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    /// 纯色方块图标；浅色底（赭橙）配深色图标，深色底（石板蓝）配奶油色
    private func iconTile(_ name: String, _ color: Color, _ foreground: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 20))
            .foregroundStyle(foreground)
            .frame(width: 46, height: 46)
            .background(RoundedRectangle(cornerRadius: Theme.artRadius, style: .continuous).fill(color))
    }
}

struct PlaylistDetailView: View {
    let title: String
    let tracks: [Track]
    let playlistID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.ui(22, .bold)).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            SongListView(tracks: tracks, playlistID: playlistID)
        }
        .navigationTitle(title)
    }
}
