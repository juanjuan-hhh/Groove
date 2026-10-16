import SwiftUI

/// "歌曲" 标签页：全部歌曲，按当前排序方式排列
struct SongsTab: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let list = library.sorted(library.tracks, by: library.sort, ascending: library.ascending)
        SongListView(tracks: list, sections: library.sections(for: list, sort: library.sort), showSortMenu: true)
    }
}

/// 窗口够宽时歌曲列表分栏显示：歌名 | 歌手 | 专辑 | 格式 | 时长（和 Apple Music 的「歌曲」页一样）
private struct SongListWideKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var songListWide: Bool {
        get { self[SongListWideKey.self] }
        set { self[SongListWideKey.self] = newValue }
    }
}

/// 分栏时各栏的宽度（表头和每一行共用，保证对齐）
enum SongColumns {
    static let minWidth: CGFloat = 860   // 窗口内容宽过这个才分栏
    static let format: CGFloat = 150
    static let time: CGFloat = 48
    static let menu: CGFloat = 24
    static let leading: CGFloat = 24
    static let trailing: CGFloat = 36
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
        GeometryReader { geo in
            let wide = geo.size.width >= SongColumns.minWidth
            content(wide: wide).environment(\.songListWide, wide)
        }
    }

    private func content(wide: Bool) -> some View {
        VStack(spacing: 0) {
            header
            ThemeDivider()
            if wide && !tracks.isEmpty { columnHeader }
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

            if library.isScanning && library.showsScanProgress {
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

    /// 分栏时的表头
    private var columnHeader: some View {
        HStack(spacing: 12) {
            Text("歌名").padding(.leading, 58).frame(maxWidth: .infinity, alignment: .leading)
            Text("歌手").frame(maxWidth: .infinity, alignment: .leading)
            Text("专辑").frame(maxWidth: .infinity, alignment: .leading)
            Text("格式").frame(width: SongColumns.format, alignment: .leading)
            Text("时长").frame(width: SongColumns.time, alignment: .trailing)
            Color.clear.frame(width: SongColumns.menu, height: 1)
        }
        .font(.ui(11, .bold))
        .foregroundStyle(Theme.text3)
        .padding(.leading, SongColumns.leading)
        .padding(.trailing, SongColumns.trailing)
        .padding(.vertical, 6)
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
    @Environment(\.songListWide) private var wide
    @State private var hovering = false

    var body: some View {
        Group {
            if wide { wideRow } else { narrowRow }
        }
        .padding(.leading, SongColumns.leading)
        .padding(.trailing, SongColumns.trailing)
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

    private var isCurrent: Bool { player.current?.id == track.id }

    /// 宽窗口：分栏
    private var wideRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(track: track, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.ui(14, isCurrent ? .bold : .medium))
                        .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                        .lineLimit(1)
                    QualityBadge(quality: track.quality)
                }
                Spacer(minLength: 4)
                if isCurrent { PlayingBars(isPlaying: player.isPlaying) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(track.artist).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(track.album).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(track.formatDescription).lineLimit(1).frame(width: SongColumns.format, alignment: .leading)
            Text(formatTime(track.duration)).monospacedDigit().frame(width: SongColumns.time, alignment: .trailing)
            menu.frame(width: SongColumns.menu)
        }
        .font(.ui(13))
        .foregroundStyle(Theme.text2)
    }

    private var menu: some View {
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

    /// 窄窗口：两行
    private var narrowRow: some View {
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
                PlayingBars(isPlaying: player.isPlaying)
            }
            menu
        }
    }
}

/// 右侧的 A–Z 快速索引：点一下或者按住上下拖动都能跳，旁边显示一个大字母（和 iPhone 版一样）；
/// 支持力度感应的触控板每换一个字母轻轻震一下
struct AlphabetIndex: View {
    let letters: [String]
    let onSelect: (String) -> Void

    /// 鼠标正停在哪个字母上（松开后为 nil）
    @State private var active: String?

    private let rowHeight: CGFloat = 15
    private let vPad: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.ui(10, .bold))
                    .foregroundStyle(active == letter ? Theme.accent : Theme.text2)
                    .frame(width: 18, height: rowHeight)
            }
        }
        .padding(.vertical, vPad)
        .background(Capsule().fill(Theme.card))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let i = Int(((value.location.y - vPad) / rowHeight).rounded(.down))
                    let letter = letters[min(max(i, 0), letters.count - 1)]
                    guard letter != active else { return }
                    active = letter
                    onSelect(letter)
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.2)) { active = nil }
                }
        )
        // 左边显示一个大字母，知道现在到了哪
        .overlay(alignment: .leading) {
            if let active {
                Text(active)
                    .font(.ui(26, .heavy))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(Theme.accent))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                    .offset(x: -64)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .padding(.trailing, 0)
    }
}
