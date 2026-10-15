import AVFoundation
import AVKit
import SwiftUI

/// 隔空播放（AirPlay）按钮：点开选择从哪个设备出声（Mac 扬声器、耳机、蓝牙、AirPlay 音箱）
struct OutputDevicePicker: NSViewRepresentable {
    let player: AVPlayer
    var size: CGFloat = 28

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        let cream = NSColor(Theme.text), accent = NSColor(Theme.accent)
        view.setRoutePickerButtonColor(cream, for: .normal)
        view.setRoutePickerButtonColor(cream.withAlphaComponent(0.7), for: .normalHighlighted)
        // 正在用 AirPlay 等外接设备时变成赭橙色
        view.setRoutePickerButtonColor(accent, for: .active)
        view.setRoutePickerButtonColor(accent.withAlphaComponent(0.7), for: .activeHighlighted)
        view.toolTip = "选择播放设备"
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVRoutePickerView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}
