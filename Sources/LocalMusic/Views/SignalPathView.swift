import SwiftUI

/// 「音频链路」：点正在播放页的格式标签打开。从源文件到声卡一级一级列出来，
/// 值都是当场从文件和 Core Audio 读的；打开期间每 1.5 秒刷新一次（换歌、换设备、切采样率都能看到）
struct SignalPathView: View {
    @Environment(PlayerController.self) private var player
    @State private var path: SignalPath?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ChipText(text: "音频链路", color: Theme.accent, font: .ui(13, .bold), hPad: 12, vPad: 4)
                Spacer()
                if let path { summary(path) }
            }
            .padding(12)
            if let path, !path.bitPerfect {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(path.reasons, id: \.self) { reason in
                        Text("· " + reason).font(.ui(11)).foregroundStyle(Theme.text2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            ThemeDivider()
            if let path {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(path.stages.enumerated()), id: \.element.id) { i, stage in
                        stageView(stage, isLast: i == path.stages.count - 1)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(30)
            }
        }
        .frame(width: 340)
        .background(Theme.card)
        .task(id: player.current?.id) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func refresh() async {
        guard let track = player.current else { path = nil; return }
        let volume = player.outputVolume
        let uid = player.outputDeviceUID
        path = await Task.detached(priority: .userInitiated) {
            SignalPath.read(track: track, volume: volume, deviceUID: uid)
        }.value
    }

    private func summary(_ path: SignalPath) -> some View {
        HStack(spacing: 4) {
            Image(systemName: path.bitPerfect ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
            Text(path.bitPerfect ? "比特完美" : (path.reasons.first == "未独占，经过系统混音" ? "经过系统混音" : "已处理"))
                .font(.ui(12, .bold))
        }
        .foregroundStyle(path.bitPerfect ? Theme.cream : Theme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(path.bitPerfect ? Theme.teal : Theme.mustard))
    }

    private func stageView(_ stage: SignalPath.Stage, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // 左边一条竖线把四级串起来
            VStack(spacing: 0) {
                Image(systemName: stage.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.sage))
                if !isLast {
                    Rectangle().fill(Theme.track).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(stage.title).font(.ui(13, .bold)).foregroundStyle(Theme.text)
                    .frame(height: 26, alignment: .center)
                ForEach(stage.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.label).font(.ui(11)).foregroundStyle(Theme.text3)
                            .frame(width: 56, alignment: .leading)
                        Text(row.value).font(.ui(12, .semibold).monospacedDigit())
                            .foregroundStyle(row.ok == false ? Theme.terra : Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if row.ok == true {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.sage)
                        }
                    }
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
