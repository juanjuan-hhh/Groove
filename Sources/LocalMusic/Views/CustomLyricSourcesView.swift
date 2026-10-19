import SwiftUI

/// 设置里的「自定义歌词源…」：自己添加歌词网址。默认一个都没有；改了马上保存
struct CustomLyricSourcesView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [CustomLyricSource] = CustomLyricSources.load()
    /// 每个源「测试」的结果
    @State private var testResults: [UUID: String] = [:]
    @State private var testing: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            ThemeDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    intro
                    ForEach($sources) { $source in
                        row($source)
                    }
                    addButton
                }
                .padding(18)
            }
        }
        .frame(width: 600, height: 520)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .onChange(of: sources) { _, list in CustomLyricSources.save(list) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ChipText(text: "自定义歌词源", color: Theme.accent, font: .ui(14, .bold), hPad: 14, vPad: 5)
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

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("内置的歌词来源只有 LRCLIB。找不到时，会按下面的顺序试你添加的歌词源（只用带时间轴的歌词），「联网搜索」里也会多出对应的一栏。")
            Text("网址里可以写 {title} 歌名、{artist} 歌手、{album} 专辑、{duration} 时长（秒），会自动换成这首歌的信息。网址返回 LRC 歌词文本，或者 LRCLIB 格式的 JSON（syncedLyrics / plainLyrics）都可以。")
            Text("你添加的歌词源由你自己负责，请只使用你有权使用的来源。")
                .foregroundStyle(Theme.mustard)
        }
        .font(.ui(12))
        .foregroundStyle(Theme.text2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ source: Binding<CustomLyricSource>) -> some View {
        let id = source.wrappedValue.id
        let index = sources.firstIndex { $0.id == id } ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: source.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(source.wrappedValue.enabled ? "已启用" : "已停用")
                field("名称", text: source.name)
                    .frame(width: 140)
                Spacer()
                iconButton("chevron.up", help: "往前挪") { move(index, by: -1) }
                    .disabled(index == 0)
                iconButton("chevron.down", help: "往后挪") { move(index, by: 1) }
                    .disabled(index == sources.count - 1)
                testButton(source.wrappedValue)
                iconButton("trash", help: "删除") {
                    sources.removeAll { $0.id == id }
                    testResults[id] = nil
                }
            }
            field("https://example.com/lyrics?title={title}&artist={artist}", text: source.template)
            if let result = testResults[id] {
                Text(result).font(.ui(11, .semibold)).foregroundStyle(Theme.text2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.card))
        .opacity(source.wrappedValue.enabled ? 1 : 0.6)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.ui(13))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.surface))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.text2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.surface))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 用正在放（或选中）的这首歌试一下这个源
    private func testButton(_ source: CustomLyricSource) -> some View {
        Button {
            Task { await test(source) }
        } label: {
            HStack(spacing: 5) {
                if testing.contains(source.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "play.circle").font(.system(size: 11, weight: .bold))
                }
                Text("测试").font(.ui(12, .bold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.surface))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(testing.contains(source.id))
        .help("用当前这首歌试一下")
    }

    private var addButton: some View {
        Button {
            sources.append(CustomLyricSource(name: "歌词源 \(sources.count + 1)", template: ""))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("添加歌词源").font(.ui(13, .bold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Theme.surface))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard sources.indices.contains(index), sources.indices.contains(target) else { return }
        sources.swapAt(index, target)
    }

    private func test(_ source: CustomLyricSource) async {
        guard let track = player.current else {
            testResults[source.id] = "先放一首歌（或在列表里选中一首）再测试"
            return
        }
        let artist = track.hasKnownArtist ? track.artist : ""
        let album = track.hasKnownAlbum ? track.album : ""
        guard CustomLyricSources.url(source.template, title: track.title, artist: artist, album: album,
                                     duration: track.duration) != nil else {
            testResults[source.id] = "网址无效：要以 http:// 或 https:// 开头"
            return
        }
        testing.insert(source.id)
        defer { testing.remove(source.id) }
        let result = await CustomLyricSources.fetch(source, title: track.title, artist: artist, album: album,
                                                    duration: track.duration)
        guard let result else {
            testResults[source.id] = "「\(track.title)」：没找到歌词（或者连不上、看不懂返回的内容）"
            return
        }
        let lines = LRCParser.parse(result.text).count
        testResults[source.id] = "「\(track.title)」：找到了 · \(result.synced ? "带时间轴" : "纯文本（自动联网时不会用）") · 共 \(lines) 行"
    }
}
