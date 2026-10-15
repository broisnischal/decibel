import BSKernel
import CoreAudio
import Foundation
import os

/// Which processes get their own volume, and which are left alone entirely.
public struct RoutePlan: Equatable, Sendable {
    public struct AppTap: Equatable, Sendable {
        public var appID: String
        public var processes: [AudioObjectID]

        public init(appID: String, processes: [AudioObjectID]) {
            self.appID = appID
            self.processes = processes.sorted()
        }
    }

    /// Apps mixed at their own gain. At most `maxAppTaps`.
    public var appTaps: [AppTap] = []
    /// Processes left out of every tap, e.g. apps recording the output device (loopback drivers).
    public var excluded: Set<AudioObjectID> = []

    public static let maxAppTaps = Int(BS_MAX_SOURCES) - 1

    public init() {}
}

/// Routes all system audio through a `SoundProcessor`, with no virtual driver:
///
///     apps ─▶ global tap (everything else) ─┐
///     app A ─▶ tap A ─┐                     │   apps are muted while tapped
///     app B ─▶ tap B ─┤                     │
///                     ▼                     ▼
///     private aggregate device [ output device + taps ] ─▶ BSKernelIOProc: per-app gain, mix, DSP ─▶ output
///
/// Our own process is excluded from every tap, so the processed signal we play is not captured again.
/// Destroying the router (or the process exiting) removes the taps and restores normal playback.
public final class SystemAudioRouter {
    public let outputDevice: AudioDevice
    public let processor: SoundProcessor
    public let sampleRate: Double
    public private(set) var plan: RoutePlan

    private var taps: [AudioObjectID]          // Global tap first, then one per mixed app.
    private var descriptions: [CATapDescription]
    private let ownProcess: AudioObjectID
    private var aggregateID: AudioObjectID
    private var ioProcID: AudioDeviceIOProcID?
    private let sourceForApp: [String: Int]

    private static let log = Logger(subsystem: "io.github.broisnischal.forte", category: "router")

    /// Our private aggregate devices are visible to this process; device lists hide them by this UID prefix.
    public static let aggregateUIDPrefix = "io.github.broisnischal.forte.aggregate."

    public init(outputDevice: AudioDevice, settings: SoundSettings, plan requested: RoutePlan = RoutePlan(),
                appGains: [String: Float] = [:]) throws {
        var plan = requested
        plan.appTaps = Array(plan.appTaps.prefix(RoutePlan.maxAppTaps))

        var taps: [AudioObjectID] = []
        var descriptions: [CATapDescription] = []
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?

        do {
            let ownProcess = try HAL.processObject(for: getpid())
            guard ownProcess != kAudioObjectUnknown else {
                throw CoreAudioError(status: kAudioHardwareBadObjectError, operation: "Looking up the Forte audio process")
            }

            func makeTap(_ description: CATapDescription, _ name: String) throws -> String {
                description.uuid = UUID()
                description.name = name
                description.isPrivate = true
                description.muteBehavior = .mutedWhenTapped
                var tap = AudioObjectID(kAudioObjectUnknown)
                try check(AudioHardwareCreateProcessTap(description, &tap), "Creating the \(name) tap")
                taps.append(tap)
                descriptions.append(description)
                return description.uuid.uuidString
            }

            var tapUIDs = [try makeTap(CATapDescription(stereoGlobalTapButExcludeProcesses: Self.globalExclusions(plan, own: ownProcess)),
                                       "Forte")]
            for app in plan.appTaps {
                tapUIDs.append(try makeTap(CATapDescription(stereoMixdownOfProcesses: app.processes), "Forte \(app.appID)"))
            }

            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Forte",
                kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputDevice.uid,
                kAudioAggregateDeviceIsPrivateKey: 1,
                kAudioAggregateDeviceIsStackedKey: 0,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDevice.uid]],
                kAudioAggregateDeviceTapListKey: tapUIDs.map { [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: 1] },
            ]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Creating the output route")

            // Aggregate inputs are the sub-device's input streams followed by one stream per tap, in tap-list order.
            let deviceInputs = try AudioDevice.streamCount(outputDevice.id, scope: kAudioObjectPropertyScopeInput)
            let streams = try HAL.readArray(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, zero: AudioStreamID(0))
            guard streams.count == deviceInputs + tapUIDs.count else {
                throw CoreAudioError(status: kAudioHardwareIllegalOperationError,
                                     operation: "Attaching \(tapUIDs.count) taps (found \(streams.count - deviceInputs) streams)")
            }
            for stream in streams[deviceInputs...] {
                let format = try HAL.read(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
                guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      format.mBitsPerChannel == 32 else {
                    throw CoreAudioError(status: kAudioDeviceUnsupportedFormatError, operation: "Reading the system audio format")
                }
            }

            let rate = try HAL.read(aggregate, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
            guard let processor = SoundProcessor(sampleRate: rate) else {
                throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "Allocating the audio processor")
            }
            processor.apply(settings)
            var sourceForApp: [String: Int] = [:]
            for (i, app) in plan.appTaps.enumerated() {
                sourceForApp[app.appID] = i + 1
                processor.setSourceGain(appGains[app.appID] ?? 1, source: i + 1)
            }
            processor.setSources(streams: (0..<tapUIDs.count).map { UInt32(deviceInputs + $0) })

            try check(AudioDeviceCreateIOProcID(aggregate, BSKernelIOProc, UnsafeMutableRawPointer(processor.kernel), &procID),
                      "Installing the audio callback")
            if deviceInputs > 0, let procID {
                let status = BSDeviceSetInputStreamUsage(aggregate, procID, UInt32(deviceInputs))
                if status != noErr { Self.log.error("Could not disable sub-device inputs: \(status)") }
            }
            try check(AudioDeviceStart(aggregate, procID), "Starting audio")

            Self.log.notice("""
                Routing via \(outputDevice.name, privacy: .public) at \(rate, privacy: .public) Hz: \
                \(plan.appTaps.count, privacy: .public) app tap(s), input offset \(deviceInputs, privacy: .public), \
                \(plan.excluded.count, privacy: .public) loopback reader(s) excluded
                """)

            self.outputDevice = outputDevice
            self.processor = processor
            self.sampleRate = rate
            self.plan = plan
            self.taps = taps
            self.descriptions = descriptions
            self.ownProcess = ownProcess
            self.aggregateID = aggregate
            self.ioProcID = procID
            self.sourceForApp = sourceForApp
        } catch {
            Self.destroy(taps: taps, aggregate: aggregate, ioProc: procID)
            throw error
        }
    }

    deinit {
        Self.destroy(taps: taps, aggregate: aggregateID, ioProc: ioProcID)
    }

    private static func globalExclusions(_ plan: RoutePlan, own: AudioObjectID) -> [AudioObjectID] {
        let mixed = Set(plan.appTaps.flatMap(\.processes))
        return [own] + plan.excluded.union(mixed).subtracting([own]).sorted()
    }

    /// Applies process changes to the running taps without rebuilding the route (no glitch). Returns false when
    /// the set of mixed apps differs, which needs a rebuild.
    public func update(to newPlan: RoutePlan) -> Bool {
        guard newPlan.appTaps.map(\.appID) == plan.appTaps.map(\.appID) else { return false }
        // Add processes to their app tap before removing them from the global tap, so they never play unmuted.
        for (i, app) in newPlan.appTaps.enumerated() where app.processes != plan.appTaps[i].processes {
            descriptions[i + 1].processes = app.processes
            guard Self.setDescription(descriptions[i + 1], on: taps[i + 1]) else { return false }
        }
        let exclusions = Self.globalExclusions(newPlan, own: ownProcess)
        if exclusions != Self.globalExclusions(plan, own: ownProcess) {
            descriptions[0].processes = exclusions
            guard Self.setDescription(descriptions[0], on: taps[0]) else { return false }
        }
        plan = newPlan
        return true
    }

    private static func setDescription(_ description: CATapDescription, on tap: AudioObjectID) -> Bool {
        var address = HAL.address(kAudioTapPropertyDescription)
        var reference = description
        let status = withUnsafeMutablePointer(to: &reference) {
            AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status != noErr { log.error("Updating tap \(tap) failed: \(status)") }
        return status == noErr
    }

    public func mixes(_ appID: String) -> Bool { sourceForApp[appID] != nil }

    /// Live per-app gain (0 mutes). No effect for apps without their own tap.
    public func setGain(_ gain: Float, forApp appID: String) {
        guard let source = sourceForApp[appID] else { return }
        processor.setSourceGain(gain, source: source)
    }

    /// Pre-gain peak since the last read, for apps with their own tap.
    public func readPeak(forApp appID: String) -> Float? {
        sourceForApp[appID].map { processor.readSourcePeak(source: $0) }
    }

    private static func destroy(taps: [AudioObjectID], aggregate: AudioObjectID, ioProc: AudioDeviceIOProcID?) {
        if aggregate != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(aggregate, ioProc)
                AudioDeviceDestroyIOProcID(aggregate, ioProc) // Blocks until the callback has returned.
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        for tap in taps { AudioHardwareDestroyProcessTap(tap) }
    }
}
