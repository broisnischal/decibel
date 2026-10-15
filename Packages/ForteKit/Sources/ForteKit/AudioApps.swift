import AppKit
import CoreAudio
import Darwin

/// An application producing audio, with all of its helper processes (browser GPU/audio helpers, etc.).
public struct AudioApp: Identifiable, Hashable, Sendable {
    /// Bundle ID of the owning app, or a process-derived key for faceless processes.
    public let id: String
    public let name: String
    /// PID of the owning app, for its icon.
    public let pid: pid_t
    public let isRegularApp: Bool
    public var processes: [AudioObjectID]
    public var isPlaying: Bool
}

@MainActor
public enum AudioApps {
    /// Alert, UI feedback and power chimes, grouped into one mixer row.
    public static let systemSoundsID = "system.sounds"
    private static let systemSoundSources: Set<String> = [
        "systemsoundserverd", "com.apple.audio.SystemSoundServer-OSX", "com.apple.loginwindow", "loginwindow",
        "com.apple.PowerChime", "PowerChime", "com.apple.SystemUIServer", "com.apple.UserNotificationCenter",
    ]

    /// Who a process belongs to. Resolving it walks the process tree, so it is cached per process object.
    private struct Identity {
        let pid: pid_t
        let key: String
        let name: String
        let ownerPID: pid_t
        let isRegularApp: Bool
    }

    private static var identities: [AudioObjectID: Identity] = [:]

    private static func identity(of object: AudioObjectID, own: pid_t) -> Identity? {
        guard let pid = try? HAL.read(object, kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0, pid != own else { return nil }
        if let cached = identities[object], cached.pid == pid { return cached }

        let owner = owningApplication(of: pid)
        guard owner?.processIdentifier != own else { return nil }
        let processBundleID = (try? HAL.readString(object, kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
        let name = processName(pid)
        let isSystemSound = owner?.activationPolicy != .regular &&
            (systemSoundSources.contains(processBundleID ?? "") || systemSoundSources.contains(name))
        let identity = Identity(
            pid: pid,
            key: isSystemSound ? systemSoundsID : owner?.bundleIdentifier ?? processBundleID ?? "process.\(name)",
            name: isSystemSound ? "System Sounds" : owner?.localizedName ?? name,
            ownerPID: owner?.processIdentifier ?? pid,
            isRegularApp: owner?.activationPolicy == .regular)
        identities[object] = identity
        return identity
    }

    /// Every process the HAL knows about, grouped by the app responsible for it. Playing apps first.
    public static func current() -> [AudioApp] {
        let own = getpid()
        let objects = (try? HAL.readArray(HAL.system, kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID(0))) ?? []
        let live = Set(objects)
        identities = identities.filter { live.contains($0.key) } // Forget processes that have gone.
        var apps: [String: AudioApp] = [:]

        for object in objects {
            guard let identity = identity(of: object, own: own) else { continue }
            let playing = ((try? HAL.read(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0

            if var app = apps[identity.key] {
                app.processes.append(object)
                app.isPlaying = app.isPlaying || playing
                apps[identity.key] = app
            } else {
                apps[identity.key] = AudioApp(id: identity.key, name: identity.name, pid: identity.ownerPID,
                                              isRegularApp: identity.isRegularApp, processes: [object], isPlaying: playing)
            }
        }
        return apps.values.sorted {
            $0.isPlaying != $1.isPlaying ? $0.isPlaying : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The app a process belongs to. Helpers (Safari's WebKit GPU process, Chrome's audio service) are attributed
    /// via the kernel's "responsible process", falling back to the parent chain.
    static func owningApplication(of pid: pid_t) -> NSRunningApplication? {
        var candidates: [pid_t] = []
        if let responsible = responsiblePID?(pid), responsible > 0 { candidates.append(responsible) }
        candidates.append(pid)
        var current = pid
        for _ in 0..<6 {
            let parent = parentPID(of: current)
            guard parent > 1 else { break }
            candidates.append(parent)
            current = parent
        }
        let apps = candidates.compactMap(NSRunningApplication.init(processIdentifier:))
        return apps.first { $0.activationPolicy == .regular } ?? apps.first
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsiblePID: ResponsibleFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "Process \(pid)" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
