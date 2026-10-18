import AppKit
import SwiftUI

/// 版本信息和检查更新：设置菜单「当前版本」打开一张小卡片，显示版本、检查更新；
/// 每次启动过几秒在后台查一次 GitHub 上最新发布的版本，有新版本就弹卡片提示（可以在卡片里关掉自动检查）
@MainActor
@Observable
final class AppUpdate {
    static let shared = AppUpdate()

    static let autoCheckDisabledKey = "updateAutoCheckDisabled"
    private static let skippedKey = "updateSkippedVersion"
    private static let latestURL = URL(string: "https://api.github.com/repos/juanjuan-hhh/Groove/releases/latest")!
    static let projectURL = URL(string: "https://github.com/juanjuan-hhh/Groove")!

    struct Release: Equatable {
        let tag: String          // "v1.2"
        let notes: String
        let page: URL
        let download: URL        // .dmg，没有就是发布页
    }

    enum State: Equatable {
        case idle, checking, upToDate, failed
        case available(Release)
    }

    private(set) var state: State = .idle

    var autoCheckDisabled: Bool {
        get { access(keyPath: \.autoCheckDisabled); return UserDefaults.standard.bool(forKey: Self.autoCheckDisabledKey) }
        set { withMutation(keyPath: \.autoCheckDisabled) { UserDefaults.standard.set(newValue, forKey: Self.autoCheckDisabledKey) } }
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    /// 启动时调用：没关掉自动检查就过几秒悄悄查一次，有新版本（且没被「跳过此版本」）才弹卡片；查不到不提示
    func checkOnLaunch() {
        guard !autoCheckDisabled else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            await check()
            if case .available(let release) = state,
               UserDefaults.standard.string(forKey: Self.skippedKey) != release.tag {
                UpdateCards.showUpdate(release)
            }
        }
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        do {
            var request = URLRequest(url: Self.latestURL, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Groove/\(Self.version) (+\(Self.projectURL.absoluteString))", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                state = .failed
                return
            }
            if (json["draft"] as? Bool) == true || (json["prerelease"] as? Bool) == true
                || !Self.isNewer(tag, than: Self.version) {
                state = .upToDate
                return
            }
            let assets = json["assets"] as? [[String: Any]] ?? []
            let dmg = assets.lazy
                .compactMap { $0["browser_download_url"] as? String }
                .first { $0.lowercased().hasSuffix(".dmg") }
                .flatMap(URL.init(string:))
            state = .available(Release(tag: tag, notes: (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                       page: page, download: dmg ?? page))
        } catch {
            state = .failed
        }
    }

    func skip(_ release: Release) {
        UserDefaults.standard.set(release.tag, forKey: Self.skippedKey)
    }

    /// "v1.2" 和 "1.1.0" 比：去掉 v，按点分开逐段比数字，短的补 0
    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

// MARK: 卡片窗口

/// 两张卡片：「当前版本」卡片和启动时发现新版本的提示卡片。都放在主窗口正中，样子和独占提示卡片一样
@MainActor
enum UpdateCards {
    private static var panel: NSPanel?

    static func showAbout() {
        show(AboutCard())
    }

    static func showUpdate(_ release: AppUpdate.Release) {
        show(UpdateCard(release: release))
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private static func show<V: View>(_ card: V) {
        panel?.orderOut(nil)
        let panel = CardPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: card.modifier(ThemedAppearance()))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        self.panel = panel
        let main = NSApp.windows.first { !($0 is NSPanel) && $0.isVisible && $0.canBecomeMain }
        let area = main?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.midY - panel.frame.height / 2))
        panel.makeKeyAndOrderFront(nil)
    }

    /// 卡片内容变高 / 变矮（检查结果出来）时跟着改窗口大小，上边不动
    fileprivate static func resize(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    /// 能成为 key window（按 Esc 关掉、回车按默认按钮）
    private final class CardPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { UpdateCards.close() }
    }
}

// MARK: 「当前版本」卡片

private struct AboutCard: View {
    private var update = AppUpdate.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Groove").font(.ui(18, .bold))
                    Text("版本 \(AppUpdate.version)（\(AppUpdate.build)）")
                        .font(.ui(12, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.text2)
                    Text("本地音乐播放器 · macOS 14 及以上")
                        .font(.ui(11))
                        .foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 0)
                CloseButton()
            }

            Button { NSWorkspace.shared.open(AppUpdate.projectURL) } label: {
                Text("github.com/juanjuan-hhh/Groove")
                    .font(.ui(12, .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .onHover { inside in if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }

            if case .available(let release) = update.state {
                ReleaseNotes(release: release)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("不自动检查更新", isOn: Binding(get: { update.autoCheckDisabled },
                                                   set: { update.autoCheckDisabled = $0 }))
                    .toggleStyle(.checkbox)
                    .font(.ui(12, .semibold))
                    .foregroundStyle(Theme.text2)
                HStack(spacing: 10) {
                    if case .available(let release) = update.state {
                        Button { NSWorkspace.shared.open(release.download) } label: {
                            ChipText(text: "下载更新", color: Theme.accent, foreground: Theme.ink, font: .ui(12, .bold), hPad: 18, vPad: 6)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button { Task { await update.check() } } label: {
                            ChipText(text: update.state == .checking ? "检查中…" : "检查更新",
                                     color: Theme.accent, foreground: Theme.ink, font: .ui(12, .bold), hPad: 18, vPad: 6)
                        }
                        .buttonStyle(.plain)
                        .disabled(update.state == .checking)
                        .keyboardShortcut(.defaultAction)
                    }
                    statusText
                    Spacer(minLength: 0)
                }
            }
        }
        .modifier(CardStyle())
    }

    @ViewBuilder private var statusText: some View {
        switch update.state {
        case .idle, .checking: EmptyView()
        case .upToDate: Text("已是最新版本").font(.ui(12, .semibold)).foregroundStyle(Theme.text2)
        case .failed: Text("检查失败，请检查网络").font(.ui(12, .semibold)).foregroundStyle(Theme.text2)
        case .available(let release): Text("发现新版本 \(release.tag)").font(.ui(12, .semibold)).foregroundStyle(Theme.accent)
        }
    }
}

// MARK: 启动时发现新版本的卡片

private struct UpdateCard: View {
    let release: AppUpdate.Release

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.accent.opacity(0.15)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("发现新版本 \(release.tag)").font(.ui(15, .bold))
                    Text("当前版本 \(AppUpdate.version)").font(.ui(12)).foregroundStyle(Theme.text2)
                }
                Spacer(minLength: 0)
                CloseButton()
            }
            ReleaseNotes(release: release)
            HStack(spacing: 10) {
                Button {
                    AppUpdate.shared.skip(release)
                    UpdateCards.close()
                } label: {
                    Text("跳过此版本").font(.ui(12, .semibold)).foregroundStyle(Theme.text2)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { UpdateCards.close() } label: {
                    ChipText(text: "稍后", color: Theme.surface, foreground: Theme.text, font: .ui(12, .bold), hPad: 16, vPad: 6)
                }
                .buttonStyle(.plain)
                Button {
                    NSWorkspace.shared.open(release.download)
                    UpdateCards.close()
                } label: {
                    ChipText(text: "下载更新", color: Theme.accent, foreground: Theme.ink, font: .ui(12, .bold), hPad: 18, vPad: 6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .modifier(CardStyle())
    }
}

/// 新版本的更新说明（发布页上写的），太长可以滚
private struct ReleaseNotes: View {
    let release: AppUpdate.Release

    /// 发布说明是 Markdown：标题去掉 #（加粗显示），**粗体**、链接照常显示，「- 」换成「• 」
    private var formatted: AttributedString {
        // GitHub 返回的是 \r\n 换行，先统一成 \n，不然每行之间多出一个空行
        let lines = release.notes.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { line -> String in
            var text = line
            if let hashes = text.range(of: "^#{1,6}\\s*", options: .regularExpression) {
                text = "**" + text[hashes.upperBound...] + "**"
            }
            if let bullet = text.range(of: "^\\s*[-*]\\s+", options: .regularExpression) {
                text.replaceSubrange(bullet, with: "• ")
            }
            return text
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: lines.joined(separator: "\n"), options: options))
            ?? AttributedString(release.notes)
    }

    var body: some View {
        if !release.notes.isEmpty {
            ScrollView {
                Text(formatted)
                    .font(.ui(12))
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface.opacity(0.6)))
        }
    }
}

private struct CloseButton: View {
    var body: some View {
        Button { UpdateCards.close() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.text2)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.surface))
        }
        .buttonStyle(.plain)
        .help("关闭")
    }
}

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(width: 360)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.line, lineWidth: 1)
            }
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { UpdateCards.resize(to: $0) }
    }
}
