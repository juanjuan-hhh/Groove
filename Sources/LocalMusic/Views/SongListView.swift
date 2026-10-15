import SwiftUI

/// "歌曲" 标签页：全部歌曲，按当前排序方式排列
struct SongsTab: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let list = library.sorted(library.tracks, by: library.sort, ascending: library.ascending)
        SongListView(tracks: list, sections: library.sections(for: list, sort: library.sort), showSortMenu: true)
    }
}

/// 歌曲列表（带顶部的 播放全部 / 随机 / 循环 / 排序，和右侧 A–Z 索引）
struct SongListView: View {
    let tracks: [Track]
    var sections: [TrackSection]? = nil
    var showSortMenu = false
    var playlistID: UUID? = nil

    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(library.isScanning ? "正在扫描…" : "没有歌曲").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                if player.shuffle { player.playShuffled(tracks) } else { player.play(tracks) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill").font(.system(size: 15))
                    Text("\(tracks.count) 首歌曲").font(.system(size: 15, weight: .medium))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)

            if library.isScanning {
                ProgressView().controlSize(.small)
                Text("正在扫描 \(library.scanned)/\(library.scanTotal)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            IconButton(systemName: "shuffle", active: player.shuffle, help: player.shuffle ? "随机播放：开" : "随机播放：关") {
                player.toggleShuffle()
            }
            IconButton(systemName: player.repeatMode.symbol, help: player.repeatMode.label) {
                player.cycleRepeat()
            }
            if showSortMenu { sortMenu }
        }
        .padding(.leading, 24)
        .padding(.trailing, 20)
        .padding(.vertical, 8)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SongSort.allCases) { option in
                Button {
                    library.setSort(option)
                } label: {
                    if library.sort == option {
                        Label("按\(option.rawValue)", systemImage: "checkmark")
                    } else {
                        Text("按\(option.rawValue)")
                    }
                }
            }
            Divider()
            Button(library.ascending ? "改为倒序" : "改为正序") { library.toggleAscending() }
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 15, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("排序")
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let sections {
                        ForEach(sections) { section in
                            Text(section.id)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 24)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                                .id("section-\(section.id)")
                            ForEach(section.tracks) { row($0) }
                        }
                    } else {
                        ForEach(tracks) { row($0) }
                    }
                }
                .padding(.bottom, 12)
            }
            .overlay(alignment: .trailing) {
                if let sections, sections.count > 1 {
                    AlphabetIndex(letters: sections.map(\.id)) { letter in
                        proxy.scrollTo("section-\(letter)", anchor: .top)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let current = player.current, tracks.contains(where: { $0.id == current.id }) {
                    Button {
                        withAnimation { proxy.scrollTo(current.id, anchor: .center) }
                    } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 38, height: 38)
                            .background(.regularMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 40)
                    .padding(.bottom, 16)
                    .help("定位到正在播放的歌曲")
                }
            }
        }
    }

    private func row(_ track: Track) -> some View {
        TrackRow(track: track, playlistID: playlistID) {
            player.play(tracks, startAt: tracks.firstIndex { $0.id == track.id } ?? 0)
        }
        .id(track.id)
    }
}

struct TrackRow: View {
    let track: Track
    var playlistID: UUID?
    let onPlay: () -> Void

    @Environment(PlayerController.self) private var player
    @State private var hovering = false

    var body: some View {
        let isCurrent = player.current?.id == track.id
        HStack(spacing: 12) {
            ArtworkView(track: track, size: 46, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    QualityBadge(quality: track.quality)
                    Text("\(track.artist) | \(formatTime(track.duration))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
            }
            Menu {
                TrackMenuItems(track: track, playlistID: playlistID, onPlay: onPlay)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0.45)
        }
        .padding(.leading, 24)
        .padding(.trailing, 36)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
                .padding(.horizontal, 10)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onPlay)
        .contextMenu { TrackMenuItems(track: track, playlistID: playlistID, onPlay: onPlay) }
        .help("双击播放")
    }
}

/// 右侧的 A–Z 快速索引
struct AlphabetIndex: View {
    let letters: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(letters, id: \.self) { letter in
                Button {
                    onSelect(letter)
                } label: {
                    Text(letter)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 6)
    }
}
