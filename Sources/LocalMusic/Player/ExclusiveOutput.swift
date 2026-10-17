import AVFoundation
import CoreAudio
import Observation

/// DSD 在独占时怎么输出：转成 PCM（默认，哪里都能放），或者 DoP 原样交给支持 DSD 的解码器
enum DSDOutputMode: String, CaseIterable, Identifiable {
    case pcm, dop
    var id: Self { self }
    var label: String { self == .pcm ? "PCM 转换" : "DoP（需解码器支持）" }
}

/// 一个输出设备（扬声器、耳机口、USB 解码器……）
struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// 输出设备和「独占输出」：
/// - 选了设备就让播放器直接输出到那个设备（不跟随系统默认）
/// - 打开独占时：把设备整个占住（Core Audio 的 Hog Mode，别的 App 的声音进不来），
///   并且按每首歌的采样率切换设备的采样率（44.1k 的歌就用 44.1k 输出，不经过系统重采样）。
///   暂停一会儿、关掉开关、拔掉设备、退出 App 时把设备还给系统、恢复原来的采样率
@MainActor
@Observable
final class ExclusiveOutput {
    static let shared = ExclusiveOutput()

    static let enabledKey = "exclusiveOutput"
    static let deviceKey = "outputDeviceUID"
    static let dsdModeKey = "dsdOutputMode"

    /// 所有能输出声音的设备（插拔时自动更新）
    private(set) var devices: [OutputDevice] = []
    /// 选中的设备，空字符串 = 跟随系统
    private(set) var selectedUID: String = UserDefaults.standard.string(forKey: ExclusiveOutput.deviceKey) ?? ""
    private(set) var enabled: Bool = UserDefaults.standard.bool(forKey: ExclusiveOutput.enabledKey)
    private(set) var dsdMode: DSDOutputMode =
        DSDOutputMode(rawValue: UserDefaults.standard.string(forKey: ExclusiveOutput.dsdModeKey) ?? "") ?? .pcm
    /// 输出设置（设备、独占、DSD 方式）变了，或者设备插拔了：播放器正在放 DSD 时要重新决定 PCM / DoP。
    /// 返回 true 表示播放器已经重新载入了（这时不用再 reapply）
    @ObservationIgnored var configChanged: (() -> Bool)?
    /// 独占中设备现在的采样率（界面上显示「输出 96kHz」），没在独占时为 nil
    private(set) var outputRate: Double?
    /// 短暂提示（设备拔掉了之类），几秒后自动清掉
    private(set) var notice: String?

    /// 正在独占的设备，以及占用前它原来的采样率（还回去时恢复）
    @ObservationIgnored private var held: (id: AudioDeviceID, originalRate: Double)?
    /// DoP 时改过声卡的物理格式（改成整数），还回去时恢复
    @ObservationIgnored private var originalFormat: (stream: AudioStreamID, format: AudioStreamBasicDescription)?
    /// 这次 prepare 有没有把声卡设成 DoP 要的整数格式
    @ObservationIgnored private var dopFormatReady = false
    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var lastTrackRate: Double = 0
    @ObservationIgnored private var lastDoP = false
    @ObservationIgnored private var idleRelease: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    private init() {
        devices = Self.outputDevices()
        listenForDeviceChanges()
    }

    // MARK: 设置

    func select(_ uid: String) {
        guard uid != selectedUID else { return }
        selectedUID = uid
        UserDefaults.standard.set(uid, forKey: Self.deviceKey)
        // DoP 的数据不能在还回系统的设备上多放一下（会是一阵噪音），先停住，重新载入时再接着放
        if lastDoP { player?.pause() }
        release()
        if configChanged?() != true { reapply() }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        let handled = configChanged?() ?? false
        if !on { release() }
        if !handled { reapply() }
    }

    func setDSDMode(_ mode: DSDOutputMode) {
        guard mode != dsdMode else { return }
        dsdMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.dsdModeKey)
        _ = configChanged?()
    }


    // MARK: 播放器调用

    /// 每首歌开始播放前调用：选设备、独占、按这首歌切采样率
    /// dop：这首是 DoP 打包的 DSD，声卡还要设成 24/32 位整数格式（浮点格式到不了解码器的原样数据）
    func prepare(player: AVPlayer, sampleRate: Double, dop: Bool = false) {
        self.player = player
        lastTrackRate = sampleRate
        lastDoP = dop
        dopFormatReady = false
        idleRelease?.cancel()
        // 选中的设备没插着时先用系统默认，插回来后（devicesChanged）自动用回它
        let uid = devices.contains { $0.uid == selectedUID } ? selectedUID : nil
        guard enabled else {
            if player.audioOutputDeviceUniqueID != uid { player.audioOutputDeviceUniqueID = uid }
            return
        }
        // 跟随系统时：已经占住了就继续用它。占住以后系统会把「默认输出」换成别的设备，不能再去跟它
        guard let id = uid.flatMap(Self.deviceID(forUID:)) ?? held?.id ?? Self.defaultOutputDevice() else { return }
        if let held, held.id != id { release() }
        if held == nil {
            held = (id, Self.nominalRate(id))
            Self.setHog(id, take: true)
        }
        // 切采样率是异步生效的，刚设完马上读还是旧值，所以设成功就直接记目标值
        var rate = Self.nominalRate(id)
        if sampleRate > 0, let best = Self.bestRate(for: sampleRate, on: id), best != rate, Self.setNominalRate(id, best) {
            rate = best
        }
        // 独占后一定指定到这个设备（跟随系统时也写死，免得系统默认变了又跑去别的设备）
        let deviceUID = Self.uid(of: id)
        if player.audioOutputDeviceUniqueID != deviceUID { player.audioOutputDeviceUniqueID = deviceUID }
        outputRate = rate
        if dop { dopFormatReady = setIntegerFormat(id, rate: rate) }
    }

    /// DoP 现在能不能用；不能用时返回原因（音频链路里显示）
    func dopProblem(rate: Double) -> String? {
        guard enabled else { return "未开启独占输出" }
        guard let held, Self.hogOwner(held.id) == getpid() else { return "没能独占声卡" }
        guard outputRate == rate else { return "声卡不支持 \(SignalPath.khz(rate))" }
        guard dopFormatReady else { return "声卡没有 24/32 位整数格式" }
        return nil
    }

    /// 把声卡第一个输出流设成这个采样率下的 24 位（没有就 32 位）整数格式
    private func setIntegerFormat(_ id: AudioDeviceID, rate: Double) -> Bool {
        guard let stream = DeviceStatus.outputStreams(id).first else { return false }
        var addr = Self.address(kAudioStreamPropertyAvailablePhysicalFormats)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(stream, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var formats = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(),
                                                     count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.size)
        guard AudioObjectGetPropertyData(stream, &addr, 0, nil, &size, &formats) == noErr else { return false }
        let candidates = formats.filter {
            $0.mFormat.mFormatID == kAudioFormatLinearPCM
                && $0.mFormat.mFormatFlags & kAudioFormatFlagIsFloat == 0
                && $0.mFormat.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
                && $0.mSampleRateRange.mMinimum <= rate && rate <= $0.mSampleRateRange.mMaximum
                && ($0.mFormat.mBitsPerChannel == 24 || $0.mFormat.mBitsPerChannel == 32)
        }
        guard var best = (candidates.first { $0.mFormat.mBitsPerChannel == 24 } ?? candidates.first)?.mFormat else { return false }
        best.mSampleRate = rate
        guard let current = DeviceStatus.physicalFormat(id) else { return false }
        if current.mBitsPerChannel == best.mBitsPerChannel, current.mFormatFlags == best.mFormatFlags,
           current.mSampleRate == rate { return true }
        if originalFormat == nil { originalFormat = (stream, current) }
        var addrSet = Self.address(kAudioStreamPropertyPhysicalFormat)
        return AudioObjectSetPropertyData(stream, &addrSet, 0, nil,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &best) == noErr
    }

    /// 暂停时调用：暂停超过一会儿就把设备还给系统（别的 App 又能出声）
    func paused() {
        guard held != nil else { return }
        idleRelease?.cancel()
        idleRelease = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.release()
        }
    }

    /// 把设备还给系统，恢复原来的采样率
    func release() {
        idleRelease?.cancel()
        guard let held else { return }
        if Self.deviceExists(held.id) {
            if var format = originalFormat?.format, let stream = originalFormat?.stream {
                var addr = Self.address(kAudioStreamPropertyPhysicalFormat)
                AudioObjectSetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format)
            }
            if held.originalRate > 0, Self.nominalRate(held.id) != held.originalRate {
                Self.setNominalRate(held.id, held.originalRate)
            }
            Self.setHog(held.id, take: false)
        }
        self.held = nil
        originalFormat = nil
        dopFormatReady = false
        outputRate = nil
    }

    /// 设置变了：正在播的歌马上按新设置输出
    private func reapply() {
        guard let player, player.currentItem != nil else { return }
        if player.rate > 0 || !enabled {
            prepare(player: player, sampleRate: lastTrackRate, dop: lastDoP)
        }
    }

    // MARK: 插拔设备

    private func listenForDeviceChanges() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            MainActor.assumeIsolated { ExclusiveOutput.shared.devicesChanged() }
        }
    }

    private func devicesChanged() {
        let before = devices
        devices = Self.outputDevices()
        if let held, !Self.deviceExists(held.id) {
            self.held = nil
            originalFormat = nil
            dopFormatReady = false
            outputRate = nil
        }
        guard !selectedUID.isEmpty else { return }
        let wasThere = before.contains { $0.uid == selectedUID }
        let isThere = devices.contains { $0.uid == selectedUID }
        if wasThere && !isThere {
            // 选中的设备拔掉了：先改用系统默认（选择还记着，插回来自动用回它）
            let name = before.first { $0.uid == selectedUID }?.name ?? "输出设备"
            show(notice: "「\(name)」已断开，改用系统默认输出")
            if configChanged?() != true { reapply() }
        } else if !wasThere && isThere {
            if configChanged?() != true { reapply() }
        }
    }

    func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Core Audio

    nonisolated static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated static func outputDevices() -> [OutputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), let uid = uid(of: id) else { return nil }
            return OutputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    private nonisolated static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    nonisolated static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    nonisolated static func uid(of id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    nonisolated static func deviceID(forUID uid: String) -> AudioDeviceID? {
        outputDevices().first { $0.uid == uid }?.id
    }

    nonisolated static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    nonisolated static func deviceExists(_ id: AudioDeviceID) -> Bool { uid(of: id) != nil }

    nonisolated static func nominalRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }

    @discardableResult
    private nonisolated static func setNominalRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = rate
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
    }

    /// 设备支持的采样率里挑一个：有一模一样的就用它；没有就用能整除的（88.2k 的歌放到 176.4k）；
    /// 再不行就用比它高的里面最低的，都比它低就用最高的
    nonisolated static func bestRate(for rate: Double, on id: AudioDeviceID) -> Double? {
        var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return nil }
        if ranges.contains(where: { $0.mMinimum <= rate && rate <= $0.mMaximum }) { return rate }
        let rates = Set(ranges.flatMap { [$0.mMinimum, $0.mMaximum] }).sorted()
        if let multiple = rates.first(where: { $0 > rate && $0.truncatingRemainder(dividingBy: rate) == 0 }) { return multiple }
        return rates.first { $0 > rate } ?? rates.last
    }

    /// 独占（Hog Mode）：写入自己的进程号就占住；再写 -1 还回去
    private nonisolated static func setHog(_ id: AudioDeviceID, take: Bool) {
        var addr = address(kAudioDevicePropertyHogMode)
        var owner: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &owner) == noErr else { return }
        let mine = getpid()
        if take {
            guard owner != mine else { return }
            var value = mine
            AudioObjectSetPropertyData(id, &addr, 0, nil, size, &value)
        } else {
            guard owner == mine else { return }
            var value: pid_t = -1
            AudioObjectSetPropertyData(id, &addr, 0, nil, size, &value)
        }
    }

    nonisolated static func hogOwner(_ id: AudioDeviceID) -> pid_t {
        var addr = address(kAudioDevicePropertyHogMode)
        var owner: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &owner)
        return owner
    }
}
