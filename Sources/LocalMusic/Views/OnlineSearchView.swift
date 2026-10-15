import SwiftUI

/// 「联网搜索」面板：同时查 酷狗 / QQ 音乐 / iTunes（iTunes 只有封面），列出所有结果，自己选用哪个封面、哪份歌词
struct OnlineSearchView: View {
    let track: Track

    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    private enum SourceState {
        case loading
        case done([OnlineCandidate])
        case failed(String)
    }

    private enum Preview {
        case loading
        case lines([String], synced: Bool)
        case empty
    }

    private static let sources: [OnlineCandidate.Source] = [.kugou, .qq, .itunes]

    /// 点了某个来源的胶囊：只显示这个来源的结果（再点一下显示全部）
    @State private var filter: OnlineCandidate.Source?

    @State private var query = ""
    @State private var states: [OnlineCandidate.Source: SourceState] = [:]
    @State private var searchID = 0
    @State private var expanded: UUID?
    @State private var previews: [UUID: Preview] = [:]
    @State private var lyricsCache: [UUID: String] = [:]
    @State private var busy: Set<String> = []
    @State private var usedCover: UUID?
    @State private var usedLyrics: UUID?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            ThemeDivider()
            sourceBar
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Self.sources, id: \.self) { source in
                        if filter == nil || filter == source, case .done(let list) = states[source] {
                            ForEach(list) { row($0) }
                        }
                    }
                    if allEmpty {
                        Text("没有找到结果，换个关键词试试")
                            .font(.ui(13))
                            .foregroundStyle(Theme.text2)
                            .padding(.top, 40)
                    }
                }
                .padding(.vertical, 8)
            }
            searchField
        }
        // 「已换成这份歌词」这类提示：在底部搜索框上方弹出一下
        .overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.ui(14, .bold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.sage))
                    .padding(.bottom, 80)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
        .frame(width: 600, height: 640)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .task { search(initial: true) }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 12) {
            ChipText(text: "联网搜索", color: Theme.accent, font: .ui(14, .bold), hPad: 14, vPad: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.ui(14, .bold)).lineLimit(1)
                Text("\(track.artist) · \(formatTime(track.duration))")
                    .font(.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("关闭（Esc）")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// 每个来源的状态：结果数 / 加载中 / 失败。点一下只看这个来源，再点一下看全部
    private var sourceBar: some View {
        HStack(spacing: 8) {
            ForEach(Self.sources, id: \.self) { source in
                let state = states[source] ?? .loading
                let selected = filter == source
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { filter = selected ? nil : source }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(sourceColor(source)).frame(width: 8, height: 8)
                        Text(source == .itunes ? "iTunes 封面" : source.rawValue).font(.ui(12, .bold))
                            .foregroundStyle(selected ? Theme.onText : Theme.text)
                        switch state {
                        case .loading:
                            ProgressView().controlSize(.mini)
                        case .done(let list):
                            Text("\(list.count)").font(.ui(12, .bold).monospacedDigit())
                                .foregroundStyle(selected ? Theme.onText.opacity(0.7) : Theme.text2)
                        case .failed(let reason):
                            Text(reason).font(.ui(11)).foregroundStyle(Theme.mustard)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    // 选中：奶油色底（和首页分类胶囊一样）
                    .background(Capsule().fill(selected ? Theme.text : Theme.card))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(selected ? "显示全部来源" : "只看\(source.rawValue)的结果")
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: 一条结果

    private func row(_ c: OnlineCandidate) -> some View {
        let isOpen = expanded == c.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                thumbnail(c)
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.title).font(.ui(14, .bold)).lineLimit(2)
                    Text([c.artist, c.album ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
                    HStack(spacing: 6) {
                        ChipText(text: c.source.rawValue, color: sourceColor(c.source),
                                 foreground: c.source == .itunes ? Theme.ink : Theme.cream,
                                 font: .ui(10, .heavy), hPad: 7, vPad: 2)
                        if let d = c.duration, d > 0 {
                            let close = track.duration > 0 && abs(d - track.duration) <= 3
                            Text(close ? "\(formatTime(d)) 时长一致" : formatTime(d))
                                .font(.ui(11, .bold).monospacedDigit())
                                .foregroundStyle(close ? Theme.sage : Theme.text3)
                        }
                        if let synced = c.synced {
                            Text(synced ? "带时间轴" : "纯文本").font(.ui(11, .semibold)).foregroundStyle(Theme.text3)
                        }
                    }
                }
                Spacer(minLength: 8)
                if c.coverURL != nil {
                    actionButton(c, kind: "cover", label: usedCover == c.id ? "已用封面" : "用这个封面",
                                 icon: "photo", done: usedCover == c.id) { await useCover(c) }
                }
                if c.lyrics != nil {
                    actionButton(c, kind: "lyrics", label: usedLyrics == c.id ? "已用歌词" : "用这个歌词",
                                 icon: "text.quote", done: usedLyrics == c.id) { await useLyrics(c) }
                }
            }
            if isOpen { preview(c) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
            .fill(isOpen ? Theme.card : .clear))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { toggle(c) }
        .help(c.lyrics != nil ? "点击预览歌词" : "")
    }

    private func thumbnail(_ c: OnlineCandidate) -> some View {
        ZStack {
            Theme.surface
            if let url = c.coverURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView().controlSize(.mini)
                }
            } else {
                Image(systemName: c.lyrics != nil ? "text.quote" : "music.note")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: Theme.artRadius, style: .continuous))
    }

    private func actionButton(_ c: OnlineCandidate, kind: String, label: String, icon: String, done: Bool,
                              action: @escaping () async -> Void) -> some View {
        let key = "\(kind)-\(c.id)"
        return Button {
            Task {
                busy.insert(key)
                await action()
                busy.remove(key)
            }
        } label: {
            HStack(spacing: 5) {
                if busy.contains(key) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: done ? "checkmark" : icon).font(.system(size: 11, weight: .bold))
                }
                Text(label).font(.ui(12, .bold))
            }
            .foregroundStyle(done ? Theme.ink : Theme.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(done ? Theme.sage : Theme.surface))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy.contains(key))
    }

    @ViewBuilder
    private func preview(_ c: OnlineCandidate) -> some View {
        switch previews[c.id] {
        case .loading, nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在加载歌词…").font(.ui(12)).foregroundStyle(Theme.text2)
            }
            .padding(.leading, 64)
        case .empty:
            Text(c.lyrics == nil ? "这个结果只有封面，没有歌词" : "这个结果没有歌词")
                .font(.ui(12)).foregroundStyle(Theme.text2)
                .padding(.leading, 64)
        case .lines(let lines, let synced):
            VStack(alignment: .leading, spacing: 4) {
                Text(synced ? "带时间轴 · 共 \(lines.count) 行" : "纯文本 · 共 \(lines.count) 行")
                    .font(.ui(11, .bold)).foregroundStyle(Theme.text3)
                ForEach(Array(lines.prefix(10).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.ui(13)).foregroundStyle(Theme.text2).lineLimit(1)
                }
                if lines.count > 10 {
                    Text("…").font(.ui(13)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.leading, 64)
        }
    }

    // MARK: 底部搜索框

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.text2)
            TextField("歌名 歌手", text: $query)
                .textFieldStyle(.plain)
                .font(.ui(14))
                .onSubmit { search(initial: false) }
            Button { search(initial: false) } label: {
                ChipText(text: "搜索", color: Theme.accent, font: .ui(13, .bold), hPad: 14, vPad: 5)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .padding(14)
    }

    // MARK: 动作

    private var allEmpty: Bool {
        Self.sources.allSatisfy { source in
            if case .done(let list) = states[source] { return list.isEmpty }
            return false
        }
    }

    private func search(initial: Bool) {
        if initial {
            // 只用歌名搜（带上歌手反而容易搜不到）；结果里按「时长一致」等标出最像的
            query = track.title
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchID += 1
        let id = searchID
        expanded = nil
        for source in Self.sources { states[source] = .loading }
        // 三个来源同时查，哪个先回来先显示；一个失败不影响其他
        for source in Self.sources {
            Task {
                let result: SourceResult
                switch source {
                case .kugou: result = await OnlineSearch.kugou(q)
                case .qq: result = await OnlineSearch.qq(q)
                case .itunes: result = await OnlineSearch.itunes(q)
                }
                guard id == searchID else { return }
                switch result {
                case .ok(let list): states[source] = .done(list)
                case .failed(let reason): states[source] = .failed(reason)
                }
            }
        }
    }

    private func toggle(_ c: OnlineCandidate) {
        if expanded == c.id {
            expanded = nil
            return
        }
        expanded = c.id
        guard c.lyrics != nil else {
            previews[c.id] = Preview.empty
            return
        }
        guard previews[c.id] == nil else { return }
        previews[c.id] = .loading
        Task { _ = await loadLyrics(c) }
    }

    /// 取歌词并记下预览
    private func loadLyrics(_ c: OnlineCandidate) async -> String? {
        if let text = lyricsCache[c.id] { return text }
        guard let text = await OnlineSearch.lyrics(for: c) else {
            previews[c.id] = Preview.empty
            return nil
        }
        let lines = LRCParser.parse(text)
        guard !lines.isEmpty else {
            previews[c.id] = Preview.empty
            return nil
        }
        lyricsCache[c.id] = text
        previews[c.id] = .lines(lines.map(\.text), synced: lines.first?.time != nil)
        return text
    }

    private func useLyrics(_ c: OnlineCandidate) async {
        guard let text = await loadLyrics(c) else {
            expanded = c.id
            flash("这个结果没有歌词")
            return
        }
        player.applyManualLyrics(text, for: track)
        usedLyrics = c.id
        flash("已换成这份歌词")
    }

    private func useCover(_ c: OnlineCandidate) async {
        guard let url = c.coverURL, let data = await OnlineSearch.image(at: url) else {
            flash("封面下载失败")
            return
        }
        await player.applyManualCover(data, for: track)
        usedCover = c.id
        flash("已换成这张封面")
    }

    private func flash(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if message == text { message = nil }
        }
    }

    private func sourceColor(_ source: OnlineCandidate.Source) -> Color {
        switch source {
        case .kugou: return Theme.slate
        case .qq: return Theme.teal
        case .itunes: return Theme.mustard
        }
    }
}
