import AVFoundation
import AVKit
import SwiftUI

/// 隔空播放（AirPlay）按钮：点开选择从哪个设备出声（Mac 扬声器、耳机、蓝牙、AirPlay 音箱）
///
/// 菜单里打勾的是 Groove 自己单独选的设备；如果是在「控制中心 → 声音」里把整台 Mac 切到了
/// AirPlay / 蓝牙，菜单仍勾着「这台 Mac」（意思是跟随系统），这时按钮变成赭橙色，鼠标悬停显示实际设备。
struct OutputDevicePicker: View {
    let player: AVPlayer
    var size: CGFloat = 28

    var body: some View {
        // 在 body 里读，系统输出变化时按钮会跟着刷新
        let system = SystemOutputMonitor.shared
        RoutePicker(player: player, size: size, external: system.isExternal, deviceName: system.deviceName)
    }
}

private struct RoutePicker: NSViewRepresentable {
    let player: AVPlayer
    let size: CGFloat
    let external: Bool
    let deviceName: String

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        let accent = NSColor(Theme.accent)
        // Groove 单独选了外接设备时
        view.setRoutePickerButtonColor(accent, for: .active)
        view.setRoutePickerButtonColor(accent.withAlphaComponent(0.7), for: .activeHighlighted)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        if view.player !== player { view.player = player }
        apply(to: view)
    }

    /// 整台 Mac 输出到 AirPlay / 蓝牙时，平常状态也用赭橙色
    private func apply(to view: AVRoutePickerView) {
        let normal = NSColor(external ? Theme.accent : Theme.text)
        view.setRoutePickerButtonColor(normal, for: .normal)
        view.setRoutePickerButtonColor(normal.withAlphaComponent(0.7), for: .normalHighlighted)
        view.toolTip = external
            ? "正在通过系统输出「\(deviceName)」播放（控制中心 → 声音）。点这里可以给 Groove 单独选设备"
            : "选择播放设备"
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVRoutePickerView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}
