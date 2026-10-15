import AudioToolbox
import CoreAudio
import Foundation

public struct AudioDevice: Hashable, Identifiable, Sendable {
    public enum Kind: Sendable {
        case builtIn, bluetooth, usb, airPlay, display, virtual, other
    }

    public enum Scope: Sendable {
        case output, input

        var hal: AudioObjectPropertyScope {
            self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
        }
    }

    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let kind: Kind

    public init(id: AudioObjectID) throws {
        self.id = id
        self.uid = try HAL.readString(id, kAudioDevicePropertyDeviceUID)
        self.name = (try? HAL.readString(id, kAudioObjectPropertyName)) ?? "Audio Device"
        let transport = (try? HAL.read(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
        self.kind = switch transport {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: .display
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: .virtual
        default: .other
        }
    }

    // MARK: Discovery and defaults

    public static func `default`(_ scope: Scope) throws -> AudioDevice {
        let selector = scope == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
        let id = try HAL.read(HAL.system, selector, initial: AudioObjectID(kAudioObjectUnknown))
        guard id != kAudioObjectUnknown else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, operation: "Finding the \(scope) device")
        }
        return try AudioDevice(id: id)
    }

    public static func defaultOutput() throws -> AudioDevice { try `default`(.output) }

    /// Visible devices that can play (or record) audio, in HAL order. Excludes Forte's own route.
    public static func devices(_ scope: Scope) -> [AudioDevice] {
        let ids = (try? HAL.readArray(HAL.system, kAudioHardwarePropertyDevices, zero: AudioObjectID(0))) ?? []
        return ids.compactMap { id in
            guard ((try? streamCount(id, scope: scope.hal)) ?? 0) > 0,
                  ((try? HAL.read(id, kAudioDevicePropertyIsHidden, initial: UInt32(0))) ?? 0) == 0,
                  let device = try? AudioDevice(id: id),
                  !device.uid.hasPrefix(SystemAudioRouter.aggregateUIDPrefix) else { return nil }
            return device
        }
    }

    public static func outputDevices() -> [AudioDevice] { devices(.output) }

    public func makeDefault(_ scope: Scope) throws {
        let selector = scope == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
        try HAL.write(HAL.system, selector, value: id)
        if scope == .output, HAL.isSettable(HAL.system, kAudioHardwarePropertyDefaultSystemOutputDevice) {
            // Keep alerts on the same device, as System Settings does.
            try? HAL.write(HAL.system, kAudioHardwarePropertyDefaultSystemOutputDevice, value: id)
        }
    }

    public func makeDefaultOutput() throws { try makeDefault(.output) }

    // MARK: Format

    public func nominalSampleRate() throws -> Double {
        try HAL.read(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    public func setNominalSampleRate(_ rate: Double) throws {
        try HAL.write(id, kAudioDevicePropertyNominalSampleRate, value: Float64(rate))
    }

    public var canSetSampleRate: Bool { HAL.isSettable(id, kAudioDevicePropertyNominalSampleRate) && availableSampleRates.count > 1 }

    /// Discrete rates the device supports; continuous ranges are expanded to the standard rates inside them.
    public var availableSampleRates: [Double] {
        let ranges = (try? HAL.readArray(id, kAudioDevicePropertyAvailableNominalSampleRates, zero: AudioValueRange())) ?? []
        let standard: [Double] = [8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]
        var rates = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum { rates.insert(r.mMinimum) }
            else { standard.filter { $0 >= r.mMinimum && $0 <= r.mMaximum }.forEach { rates.insert($0) } }
        }
        return rates.sorted()
    }

    public func channelCount(_ scope: Scope) -> Int {
        var address = HAL.address(kAudioDevicePropertyStreamConfiguration, scope: scope.hal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public var manufacturer: String? { try? HAL.readString(id, kAudioObjectPropertyManufacturer) }

    /// Whether anything can record from this device (true for loopback drivers, which some report as USB).
    public var hasInput: Bool { ((try? Self.streamCount(id, scope: kAudioObjectPropertyScopeInput)) ?? 0) > 0 }

    static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        try HAL.readArray(device, kAudioDevicePropertyStreams, scope: scope, zero: AudioStreamID(0)).count
    }

    // MARK: Volume and mute

    /// The property and elements that control this device's volume, if any. Prefers the virtual main volume
    /// (one control that drives every channel, as the system volume keys do).
    private func volumeControl(_ scope: Scope) -> (selector: AudioObjectPropertySelector, elements: [AudioObjectPropertyElement])? {
        let virtualMain = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        if HAL.has(id, virtualMain, scope: scope.hal) { return (virtualMain, [HAL.main]) }
        if HAL.has(id, kAudioDevicePropertyVolumeScalar, scope: scope.hal) { return (kAudioDevicePropertyVolumeScalar, [HAL.main]) }
        let channels = (1...2).map(AudioObjectPropertyElement.init).filter {
            HAL.has(id, kAudioDevicePropertyVolumeScalar, scope: scope.hal, element: $0)
        }
        return channels.isEmpty ? nil : (kAudioDevicePropertyVolumeScalar, channels)
    }

    /// Volume selectors to observe for external changes (volume keys, Control Centre).
    public static let volumeSelectors = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar,
                                         kAudioDevicePropertyMute]

    public func canSetVolume(_ scope: Scope) -> Bool {
        guard let control = volumeControl(scope) else { return false }
        return control.elements.contains { HAL.isSettable(id, control.selector, scope: scope.hal, element: $0) }
    }

    /// 0...1, or nil when the device has no volume control (e.g. most HDMI displays).
    public func volume(_ scope: Scope) -> Float? {
        guard let control = volumeControl(scope) else { return nil }
        let values = control.elements.compactMap {
            try? HAL.read(id, control.selector, scope: scope.hal, element: $0, initial: Float32(0))
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    public func setVolume(_ volume: Float, _ scope: Scope) throws {
        guard let control = volumeControl(scope) else { return }
        let value = Float32(min(max(volume, 0), 1))
        for element in control.elements {
            try HAL.write(id, control.selector, scope: scope.hal, element: element, value: value)
        }
    }

    public func canMute(_ scope: Scope) -> Bool { HAL.isSettable(id, kAudioDevicePropertyMute, scope: scope.hal) }

    public func isMuted(_ scope: Scope) -> Bool? {
        guard HAL.has(id, kAudioDevicePropertyMute, scope: scope.hal) else { return nil }
        return ((try? HAL.read(id, kAudioDevicePropertyMute, scope: scope.hal, initial: UInt32(0))) ?? 0) != 0
    }

    public func setMuted(_ muted: Bool, _ scope: Scope) throws {
        try HAL.write(id, kAudioDevicePropertyMute, scope: scope.hal, value: UInt32(muted ? 1 : 0))
    }
}

public enum AudioProcesses {
    /// Processes currently recording from `device`. When that device is a loopback driver (eqMac, BlackHole,
    /// Loopback…), its companion app replays what we write; tapping that app would feed our output back to us.
    public static func readers(of device: AudioObjectID) -> Set<AudioObjectID> {
        let processes = (try? HAL.readArray(HAL.system, kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID(0))) ?? []
        return Set(processes.filter { process in
            let inputs = (try? HAL.readArray(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput,
                                             zero: AudioObjectID(0))) ?? []
            return inputs.contains(device)
        })
    }
}

/// Tracks whether any other app is playing audio, using each process's "running output" state. This needs no
/// recording permission and no tap, so the app can stay idle (and macOS's recording indicator off) until sound plays.
@MainActor
public final class AudioActivityMonitor {
    public private(set) var isActive = false
    /// Called when the set of playing processes changes; `started` is true when a process newly began output.
    public var onChange: ((_ active: Bool, _ started: Bool) -> Void)?
    private var running: Set<AudioObjectID> = []

    private var listListener: AudioPropertyListener?
    private var processListeners: [AudioObjectID: AudioPropertyListener] = [:]
    private let ownPID = getpid()

    public init() {
        listListener = try? AudioPropertyListener(object: HAL.system, selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.refreshProcesses()
        }
        refreshProcesses()
    }

    private func refreshProcesses() {
        let objects = Set((try? HAL.readArray(HAL.system, kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID(0))) ?? [])
        processListeners = processListeners.filter { objects.contains($0.key) }
        for object in objects where processListeners[object] == nil {
            guard (try? HAL.read(object, kAudioProcessPropertyPID, initial: pid_t(0))) != ownPID else { continue }
            processListeners[object] = try? AudioPropertyListener(object: object, selector: kAudioProcessPropertyIsRunningOutput) { [weak self] in
                self?.evaluate()
            }
        }
        evaluate()
    }

    /// Re-reads every process; also a cheap safety net if a change notification is missed.
    public func evaluate() {
        let now = Set(processListeners.keys.filter {
            ((try? HAL.read($0, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
        })
        guard now != running else { return }
        let started = !now.subtracting(running).isEmpty
        running = now
        isActive = !now.isEmpty
        onChange?(isActive, started)
    }
}
