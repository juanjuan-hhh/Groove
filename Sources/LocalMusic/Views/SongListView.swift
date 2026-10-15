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
            ThemeDivider()
            if tracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note").font(.system(size: 36)).foregroundStyle(Theme.text3)
                    Text(library.isScanning ? "正在扫描…" : "没有歌曲").font(.ui(14)).foregroundStyle(Theme.text2)
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
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .offset(x: 1)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.accent))
                    Text("\(tracks.count) 首歌曲").font(.ui(15, .bold)).foregroundStyle(Theme.text)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)

            if library.isScanning {
                ProgressView().controlSize(.small)
                Text("正在扫描 \(library.scanned)/\(library.scanTotal)")
                    .font(.ui(12))
                    .foregroundStyle(Theme.text2)
            }

            Spacer()

            IconButton(systemName: "shuffle", active: player.shuffle, help: player.shuffle ? "随机播放：开" : "随机播放：关") {
                player.toggleShuffle()
            }
            .foregroundStyle(player.shuffle ? Theme.accent : Theme.text2)
            IconButton(systemName: player.repeatMode.symbol, help: player.repeatMode.label) {
                player.cycleRepeat()
            }
            .foregroundStyle(player.repeatMode == .off ? Theme.text2 : Theme.accent)
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
                .foregroundStyle(Theme.text2)
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
                            ChipText(text: section.id, color: Theme.surface, foreground: Theme.text, font: .ui(12, .heavy), hPad: 9, vPad: 2)
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
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Theme.accent))
                            .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
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
            ArtworkView(track: track, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.ui(14, isCurrent ? .bold : .medium))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    QualityBadge(quality: track.quality)
                    Text("\(track.artist) | \(formatTime(track.duration))")
                        .font(.ui(12))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
            }
            Menu {
                TrackMenuItems(track: track, playlistID: playlistID, onPlay: onPlay)
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.text2)
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
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(hovering ? Theme.surface : (isCurrent ? Theme.card : .clear))
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
                        .font(.ui(10, .bold))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 18, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.card))
        .padding(.trailing, 6)
    }
}
