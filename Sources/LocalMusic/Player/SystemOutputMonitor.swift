import CoreAudio
import Foundation
import Observation

/// 盯着 Mac 的系统输出设备（控制中心 → 声音 里选的那个）。
/// Groove 默认跟随系统输出，所以系统切到 AirPlay / 蓝牙时，播放按钮也要显示成「外接设备」。
@MainActor
@Observable
final class SystemOutputMonitor {
    static let shared = SystemOutputMonitor()

    private(set) var deviceName = ""
    /// AirPlay 或蓝牙
    private(set) var isExternal = false

    private init() {
        refresh()
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        var device = AudioObjectID(0)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return }

        var transport: UInt32 = 0
        addr.mSelector = kAudioDevicePropertyTransportType
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport)
        isExternal = [kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeBluetooth,
                      kAudioDeviceTransportTypeBluetoothLE].contains(transport)

        var name: Unmanaged<CFString>?
        addr.mSelector = kAudioObjectPropertyName
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr, let name {
            deviceName = name.takeRetainedValue() as String
        }
    }
}
