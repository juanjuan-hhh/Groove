import AVFoundation
import CoreAudio

/// 输出设备的实际状态，直接从 Core Audio 读回来（不是 App 自己记的值）
struct DeviceStatus {
    var name: String
    var transport: String
    var nominalRate: Double
    /// 声卡物理格式：位深、是否浮点（USB 解码器一般是 24 / 32 位整数）
    var physicalBits: Int
    var physicalFloat: Bool
    /// 独占（Hog Mode）的进程是不是 Groove
    var hoggedByUs: Bool

    static func read(_ id: AudioDeviceID) -> DeviceStatus {
        let format = physicalFormat(id)
        return DeviceStatus(
            name: ExclusiveOutput.string(id, kAudioObjectPropertyName) ?? "未知设备",
            transport: transportName(id),
            nominalRate: ExclusiveOutput.nominalRate(id),
            physicalBits: Int(format?.mBitsPerChannel ?? 0),
            physicalFloat: format.map { $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 } ?? false,
            hoggedByUs: ExclusiveOutput.hogOwner(id) == getpid()
        )
    }

    var formatText: String {
        guard physicalBits > 0 else { return "" }
        return "\(physicalBits)位" + (physicalFloat ? "浮点" : "整数")
    }

    private static func transportName(_ id: AudioDeviceID) -> String {
        var addr = ExclusiveOutput.address(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &type)
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return "内置"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "蓝牙"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeThunderbolt: return "雷电"
        case kAudioDeviceTransportTypeFireWire: return "火线"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeAggregate: return "聚合设备"
        case kAudioDeviceTransportTypeVirtual: return "虚拟设备"
        default: return "其他"
        }
    }

    /// 第一个输出流的物理格式
    static func physicalFormat(_ id: AudioDeviceID) -> AudioStreamBasicDescription? {
        guard let stream = outputStreams(id).first else { return nil }
        var addr = ExclusiveOutput.address(kAudioStreamPropertyPhysicalFormat)
        var desc = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &addr, 0, nil, &size, &desc) == noErr else { return nil }
        return desc
    }

    static func outputStreams(_ id: AudioDeviceID) -> [AudioStreamID] {
        var addr = ExclusiveOutput.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}

/// 「音频链路」面板显示的内容：源文件 → 解码 → 处理 → 输出，以及是不是比特完美
struct SignalPath {
    struct Stage: Identifiable {
        let id: String
        let title: String
        let icon: String
        var rows: [Row]
    }

    /// 一行：名称、值，ok = true 绿色勾、false 橙色提示、nil 普通
    struct Row: Identifiable {
        let label: String
        let value: String
        var ok: Bool?
        var id: String { label }
        init(_ label: String, _ value: String, _ ok: Bool? = nil) {
            self.label = label
            self.value = value
            self.ok = ok
        }
    }

    var stages: [Stage]
    var bitPerfect: Bool
    var isDoP = false
    /// 不是比特完美的原因
    var reasons: [String]

    static func khz(_ rate: Double) -> String {
        let k = rate / 1000
        return k == k.rounded() ? "\(Int(k))kHz" : String(format: "%.1fkHz", k)
    }

    static func channelsText(_ n: Int) -> String {
        switch n {
        case 1: return "单声道"
        case 2: return "立体声"
        case 0: return ""
        default: return "\(n) 声道"
        }
    }

    /// 读文件和 Core Audio，算出整条链路（在后台线程调用）
    static func read(track: Track, stream: PlaybackStream, volume: Float, deviceUID: String?) -> SignalPath {
        var reasons: [String] = []

        // 源文件
        var channels = 0
        var sourceRows: [Row] = []
        if track.isDSD {
            channels = DSDFile.read(url: track.url)?.channels ?? 0
            sourceRows.append(Row("格式", track.codec + "（DSD）"))
            sourceRows.append(Row("采样率", (track.dsdLabel ?? "DSD") + " · " + String(format: "%.4fMHz", track.sampleRate / 1_000_000)))
            sourceRows.append(Row("位深", "1bit"))
        } else {
            if let file = try? AVAudioFile(forReading: track.url) {
                channels = Int(file.fileFormat.channelCount)
            }
            sourceRows.append(Row("格式", track.codec + (track.isLossless ? "（无损）" : "（有损）")))
            if track.isLossless && track.bitDepth > 0 { sourceRows.append(Row("位深", "\(track.bitDepth)bit")) }
            if track.sampleRate > 0 { sourceRows.append(Row("采样率", khz(track.sampleRate))) }
        }
        if channels > 0 { sourceRows.append(Row("声道", channelsText(channels))) }
        if !track.isLossless { reasons.append("源文件是有损格式") }

        // 解码：AVPlayer 统一解码成 32 位浮点；DSD 由 Groove 自己转换或打包
        var decodeRows: [Row] = []
        let streamRate: Double
        var isDoP = false
        switch stream {
        case .dop(let rate):
            isDoP = true
            streamRate = rate
            decodeRows.append(Row("方式", "DoP 封装（不解码）", true))
            decodeRows.append(Row("传输", "24bit · \(khz(rate))，0x05/0xFA 标记"))
        case .dsdPCM(let rate, let dopProblem):
            streamRate = rate
            decodeRows.append(Row("方式", "DSD → PCM \(khz(rate)) 32位浮点"))
            decodeRows.append(Row("滤波", "低通 45kHz，留 6dB 余量"))
            if let dopProblem {
                decodeRows.append(Row("DoP", "用不了：\(dopProblem)", false))
            }
            reasons.append("DSD 转换成了 PCM")
        case .file:
            streamRate = track.sampleRate
            switch track.codec {
            case "WAV", "AIFF", "CAF":
                decodeRows.append(Row("解码", "PCM \(track.bitDepth > 0 ? "\(track.bitDepth)bit " : "")→ 32位浮点"))
            default:
                decodeRows.append(Row("解码", "\(track.codec) 解码 → 32位浮点"))
            }
        }

        // 输出设备
        let deviceID = deviceUID.flatMap(ExclusiveOutput.deviceID(forUID:)) ?? ExclusiveOutput.defaultOutputDevice()
        let device = deviceID.map(DeviceStatus.read)

        // 处理
        var processRows: [Row] = []
        if volume >= 0.9999 {
            processRows.append(Row("音量", "100%（无损）", true))
        } else {
            processRows.append(Row("音量", "数字音量 \(Int((volume * 100).rounded()))%", false))
            reasons.append("数字音量 \(Int((volume * 100).rounded()))%")
        }
        if let device, streamRate > 0, device.nominalRate > 0 {
            if abs(device.nominalRate - streamRate) < 1 {
                processRows.append(Row("重采样", "无", true))
            } else {
                let who = device.hoggedByUs ? "（声卡不支持 \(khz(streamRate))）" : "（系统）"
                processRows.append(Row("重采样", "\(khz(streamRate)) → \(khz(device.nominalRate))" + who, false))
                reasons.append("重采样 \(khz(streamRate)) → \(khz(device.nominalRate))")
            }
        }
        processRows.append(Row("音效", "无", true))

        // 输出
        var outputRows: [Row] = []
        if let device {
            outputRows.append(Row("设备", device.name, nil))
            outputRows.append(Row("连接", device.transport, nil))
            let fmt = device.formatText
            outputRows.append(Row("声卡格式", khz(device.nominalRate) + (fmt.isEmpty ? "" : " · " + fmt), nil))
            outputRows.append(Row("独占", device.hoggedByUs ? "是" : "否", device.hoggedByUs))
            outputRows.append(Row("系统混音", device.hoggedByUs ? "已绕过" : "经过", device.hoggedByUs))
            if !device.hoggedByUs { reasons.insert("未独占，经过系统混音", at: 0) }
            if isDoP {
                if device.physicalFloat || device.physicalBits < 24 {
                    reasons.append("声卡是 \(device.formatText)，DoP 数据到不了解码器")
                }
            } else if !track.isDSD, track.isLossless, track.bitDepth > 0, device.physicalBits > 0, !device.physicalFloat,
                      device.physicalBits < track.bitDepth {
                reasons.append("声卡 \(device.physicalBits)位，低于源文件 \(track.bitDepth)位")
            }
        } else {
            outputRows.append(Row("设备", "读取不到输出设备", false))
            reasons.append("读取不到输出设备")
        }

        let stages = [
            Stage(id: "source", title: "源文件", icon: "doc", rows: sourceRows),
            Stage(id: "decode", title: "解码", icon: "waveform", rows: decodeRows),
            Stage(id: "process", title: "处理", icon: "slider.horizontal.3", rows: processRows),
            Stage(id: "output", title: "输出", icon: "hifispeaker", rows: outputRows),
        ]
        return SignalPath(stages: stages, bitPerfect: reasons.isEmpty, isDoP: isDoP, reasons: reasons)
    }
}
