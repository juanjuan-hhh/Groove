import AppKit
import SwiftUI

/// 封面图。没有封面时显示深色占位图。
struct ArtworkView: View {
    let track: Track?
    let size: CGFloat
    var cornerRadius: CGFloat = Theme.artRadius
    var circle = false

    @State private var image: NSImage?

    var body: some View {
        let provider = ArtworkProvider.shared
        let taskID = "\(track?.path ?? "")#\(provider.revision)"
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.surface
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.35, weight: .medium))
                    .foregroundStyle(Theme.text3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
        .task(id: taskID) {
            guard let track else {
                image = nil
                return
            }
            image = await provider.image(for: track, size: size)
        }
    }
}

/// SQ / HR 音质标签：纯色小胶囊，SQ 赭橙、HR 芥末黄
struct QualityBadge: View {
    let quality: AudioQuality

    var body: some View {
        switch quality {
        case .sq: badge("SQ", Theme.terra)
        case .hr: badge("HR", Theme.mustard)
        case .standard: EmptyView()
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        ChipText(text: text, color: color, font: .ui(9, .heavy), hPad: 5, vPad: 1)
    }
}

/// 图标按钮
struct IconButton: View {
    let systemName: String
    var size: CGFloat = 15
    var active = true
    var help = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .opacity(active ? 1 : 0.4)
                .frame(width: size + 16, height: size + 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 睡眠定时菜单
struct SleepTimerMenu: View {
    @Environment(PlayerController.self) private var player
    var size: CGFloat = 16

    var body: some View {
        Menu {
            if let deadline = player.sleepDeadline {
                Text("将在 \(deadline.formatted(date: .omitted, time: .shortened)) 停止播放")
            } else if player.stopAfterCurrent {
                Text("将在当前歌曲播完后停止")
            }
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("\(minutes) 分钟后停止") { player.setSleepTimer(minutes: minutes) }
            }
            Button("播完当前歌曲后停止") { player.setStopAfterCurrent() }
            if player.sleepActive {
                Divider()
                Button("取消定时") { player.cancelSleepTimer() }
            }
        } label: {
            Image(systemName: player.sleepActive ? "timer.circle.fill" : "timer")
                .font(.system(size: size))
                .foregroundStyle(player.sleepActive ? Theme.accent : Theme.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("睡眠定时")
    }
}

/// 歌曲的右键菜单 / "⋯" 菜单
struct TrackMenuItems: View {
    let track: Track
    var playlistID: UUID?
    let onPlay: () -> Void

    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Button("播放", action: onPlay)
        Button("下一首播放") { player.playNext(track) }
        Button("添加到播放队列") { player.addToQueue(track) }
        Divider()
        Button(library.isFavorite(track) ? "取消收藏" : "收藏") { library.toggleFavorite(track) }
        Menu("添加到歌单") {
            ForEach(library.playlists) { playlist in
                Button(playlist.name) { library.add([track], to: playlist.id) }
            }
            if !library.playlists.isEmpty { Divider() }
            Button("新建歌单…") { library.playlistDraft = [track] }
        }
        if let playlistID {
            Button("从歌单中移除") { library.remove(track, from: playlistID) }
        }
        Divider()
        Button("联网搜索封面和歌词…") { player.openOnlineSearch(for: track) }
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }
    }
}

/// 艺术家 / 文件夹 / 歌单 列表里的一行
struct GroupRow<Leading: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let leading: () -> Leading
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            leading()
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(14, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle).font(.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
            .fill(hovering ? Theme.surface : .clear).padding(.horizontal, 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
