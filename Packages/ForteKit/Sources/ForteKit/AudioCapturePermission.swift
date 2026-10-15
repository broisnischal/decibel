import Foundation

/// System Audio Recording permission (TCC service `kTCCServiceAudioCapture`).
///
/// macOS has no public API to query this before tapping, and a denied tap delivers silence while still muting
/// every app. So we preflight through TCC's C entry points, as other process-tap apps do.
/// If they ever disappear we report `.unknown` and let the system prompt on first use.
public enum AudioCapturePermission {
    public enum Status: Sendable { case authorized, denied, unknown }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }
    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let tcc, let sym = dlsym(tcc, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    public static var status: Status {
        guard let preflight = symbol("TCCAccessPreflight", as: PreflightFn.self) else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't decided yet. Returns whether access is granted.
    public static func request() async -> Bool {
        guard let request = symbol("TCCAccessRequest", as: RequestFn.self) else { return true }
        return await withCheckedContinuation { continuation in
            request(service, nil) { granted in continuation.resume(returning: granted) }
        }
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
