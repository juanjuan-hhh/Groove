import AppKit
import Observation

enum SongSort: String, CaseIterable, Identifiable, Codable {
    case title = "歌名"
    case artist = "歌手"
    case album = "专辑"
    case duration = "时长"
    case added = "修改时间"
    var id: Self { self }
}

/// 音乐库：管理音乐文件夹、扫描歌曲、收藏和歌单，并保存到本地
@MainActor
@Observable
final class LibraryStore {
    private(set) var folders: [String] = []
    private(set) var tracks: [Track] = []
    private(set) var albums: [TrackGroup] = []
    private(set) var artists: [TrackGroup] = []
    private(set) var folderGroups: [TrackGroup] = []

    private(set) var isScanning = false
    private(set) var scanned = 0
    private(set) var scanTotal = 0

    private(set) var favorites: Set<String> = []
    private(set) var playlists: [Playlist] = []

    private(set) var sort: SongSort = .title
    private(set) var ascending = true

    /// 等待命名的新歌单（里面是要加入的歌曲）
    var playlistDraft: [Track]?

    @ObservationIgnored private var byPath: [String: Track] = [:]
    @ObservationIgnored private var rescanPending = false

    private struct SavedState: Codable {
        var folders: [String]
        var favorites: [String]
        var playlists: [Playlist]
        var sort: SongSort
        var ascending: Bool
    }

    private var stateURL: URL { AppPaths.support.appendingPathComponent("state.json") }
    private var libraryURL: URL { AppPaths.support.appendingPathComponent("library.json") }

    init() {
        loadState()
        if let data = try? Data(contentsOf: libraryURL),
           let saved = try? JSONDecoder().decode([Track].self, from: data) {
            setTracks(saved)
        }
        if !folders.isEmpty { rescan() }
    }

    // MARK: 文件夹

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择存放音乐的文件夹"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if !folders.contains(path) { folders.append(path) }
        }
        saveState()
        rescan()
    }

    func removeFolder(_ path: String) {
        folders.removeAll { $0 == path }
        setTracks(tracks.filter { isInFolders($0.path) })
        saveState()
        saveTracks()
    }

    private func isInFolders(_ path: String) -> Bool {
        folders.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    // MARK: 扫描

    func rescan() {
        guard !isScanning else {
            rescanPending = true
            return
        }
        isScanning = true
        scanned = 0
        scanTotal = 0
        let roots = folders
        let existing = byPath

        Task {
            let files = await Task.detached(priority: .userInitiated) {
                LibraryStore.collectAudioFiles(in: roots)
            }.value
            scanTotal = files.count

            var result: [Track] = []
            result.reserveCapacity(files.count)
            let batchSize = 8
            for start in stride(from: 0, to: files.count, by: batchSize) {
                let batch = Array(files[start..<min(start + batchSize, files.count)])
                let read = await withTaskGroup(of: Track.self) { group -> [Track] in
                    for file in batch {
                        group.addTask {
                            if let old = existing[file.url.path], abs(old.modified.timeIntervalSince(file.modified)) < 1 {
                                return old
                            }
                            return await MetadataReader.readTrack(url: file.url, modified: file.modified)
                        }
                    }
                    var out: [Track] = []
                    for await track in group { out.append(track) }
                    return out
                }
                result.append(contentsOf: read)
                scanned = result.count
            }

            setTracks(result)
            saveTracks()
            isScanning = false
            if rescanPending {
                rescanPending = false
                rescan()
            }
        }
    }

    private struct AudioFile: Sendable {
        let url: URL
        let modified: Date
    }

    nonisolated private static func collectAudioFiles(in roots: [String]) -> [AudioFile] {
        var seen = Set<String>()
        var files: [AudioFile] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                guard MetadataReader.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, seen.insert(url.path).inserted else { continue }
                files.append(AudioFile(url: url, modified: values?.contentModificationDate ?? .distantPast))
            }
        }
        return files
    }

    private func setTracks(_ list: [Track]) {
        tracks = list
        rebuildGroups()
    }

    // MARK: 排序 / 分组 / 搜索

    func setSort(_ value: SongSort) {
        sort = value
        saveState()
    }

    func toggleAscending() {
        ascending.toggle()
        saveState()
    }

    func sorted(_ list: [Track], by sort: SongSort, ascending: Bool) -> [Track] {
        let result: [Track]
        switch sort {
        case .title:
            result = list.sorted { SortKey.less($0.titleKey, $1.titleKey) }
        case .artist:
            result = list.sorted {
                $0.artistKey == $1.artistKey ? SortKey.less($0.titleKey, $1.titleKey) : SortKey.less($0.artistKey, $1.artistKey)
            }
        case .album:
            result = list.sorted {
                if $0.albumKey != $1.albumKey { return SortKey.less($0.albumKey, $1.albumKey) }
                return Self.albumOrder($0, $1)
            }
        case .duration:
            result = list.sorted { $0.duration < $1.duration }
        case .added:
            result = list.sorted { $0.modified > $1.modified }
        }
        return ascending ? result : result.reversed()
    }

    /// 按首字母分段（只在按歌名/歌手/专辑排序时）
    func sections(for list: [Track], sort: SongSort) -> [TrackSection]? {
        let keyPath: KeyPath<Track, String>
        switch sort {
        case .title: keyPath = \.titleKey
        case .artist: keyPath = \.artistKey
        case .album: keyPath = \.albumKey
        default: return nil
        }
        var result: [TrackSection] = []
        for track in list {
            let letter = SortKey.section(track[keyPath: keyPath])
            if result.last?.id == letter {
                result[result.count - 1].tracks.append(track)
            } else {
                result.append(TrackSection(id: letter, tracks: [track]))
            }
        }
        return result
    }

    /// 搜索歌名、歌手、专辑，也支持拼音（"qingtian"）和拼音首字母（"qt"）
    func search(_ text: String) -> [Track] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        let compactQuery = SortKey.compact(query)
        let matches = tracks.filter { t in
            if t.title.lowercased().contains(query) || t.artist.lowercased().contains(query)
                || t.album.lowercased().contains(query) { return true }
            guard !compactQuery.isEmpty else { return false }
            return SortKey.compact(t.titleKey).contains(compactQuery)
                || SortKey.compact(t.artistKey).contains(compactQuery)
                || SortKey.initials(t.titleKey).hasPrefix(compactQuery)
        }
        return sorted(matches, by: .title, ascending: true)
    }

    private static func albumOrder(_ a: Track, _ b: Track) -> Bool {
        switch (a.trackNumber, b.trackNumber) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return SortKey.less(a.titleKey, b.titleKey)
        }
    }

    private func rebuildGroups() {
        byPath = Dictionary(tracks.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        albums = makeGroups(id: { $0.album }, subtitle: { Self.mostCommonArtist($0) }, order: Self.albumOrder)
        artists = makeGroups(id: { $0.artist }, subtitle: { "\($0.count) 首歌曲" }) { SortKey.less($0.titleKey, $1.titleKey) }
        folderGroups = Dictionary(grouping: tracks, by: \.folderPath)
            .map { path, list in
                TrackGroup(id: path, name: (path as NSString).lastPathComponent, subtitle: path,
                           tracks: list.sorted { SortKey.less($0.titleKey, $1.titleKey) })
            }
            .sorted { SortKey.less(SortKey.make($0.name), SortKey.make($1.name)) }
    }

    private func makeGroups(id: (Track) -> String, subtitle: ([Track]) -> String,
                            order: @escaping (Track, Track) -> Bool) -> [TrackGroup] {
        Dictionary(grouping: tracks, by: id)
            .map { name, list in
                TrackGroup(id: name, name: name, subtitle: subtitle(list), tracks: list.sorted(by: order))
            }
            .sorted { SortKey.less(SortKey.make($0.name), SortKey.make($1.name)) }
    }

    private static func mostCommonArtist(_ list: [Track]) -> String {
        let counts = Dictionary(grouping: list, by: \.artist).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key ?? Track.unknownArtist
    }

    // MARK: 收藏 / 歌单

    func isFavorite(_ track: Track) -> Bool { favorites.contains(track.path) }

    func toggleFavorite(_ track: Track) {
        if favorites.contains(track.path) { favorites.remove(track.path) } else { favorites.insert(track.path) }
        saveState()
    }

    var favoriteTracks: [Track] {
        sorted(favorites.compactMap { byPath[$0] }, by: .title, ascending: true)
    }

    func playlist(_ id: UUID) -> Playlist? { playlists.first { $0.id == id } }

    func tracks(in playlist: Playlist) -> [Track] {
        playlist.paths.compactMap { byPath[$0] }
    }

    func createPlaylist(name: String, tracks: [Track]) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        playlists.append(Playlist(name: trimmed.isEmpty ? "新歌单" : trimmed, paths: tracks.map(\.path)))
        playlistDraft = nil
        saveState()
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = trimmed
        saveState()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        saveState()
    }

    func add(_ tracks: [Track], to id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        for track in tracks where !playlists[i].paths.contains(track.path) {
            playlists[i].paths.append(track.path)
        }
        saveState()
    }

    func remove(_ track: Track, from id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].paths.removeAll { $0 == track.path }
        saveState()
    }

    // MARK: 保存

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        folders = state.folders
        favorites = Set(state.favorites)
        playlists = state.playlists
        sort = state.sort
        ascending = state.ascending
    }

    private func saveState() {
        let state = SavedState(folders: folders, favorites: Array(favorites), playlists: playlists,
                               sort: sort, ascending: ascending)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func saveTracks() {
        if let data = try? JSONEncoder().encode(tracks) {
            try? data.write(to: libraryURL, options: .atomic)
        }
    }
}
