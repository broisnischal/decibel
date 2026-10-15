import AppKit
import Observation
import os

/// The system's now-playing session (Music, Spotify, a YouTube tab…) with transport controls.
///
/// MediaRemote only serves Apple-signed processes since macOS 15.4, so the queries run in a helper library
/// (`BSNowPlaying.framework`, see NowPlayingHelper/) hosted by `/usr/bin/perl`, which streams JSON lines back.
@MainActor @Observable
final class NowPlaying {
    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
        /// Elapsed seconds at `timestamp`, advancing at `rate` while playing.
        var elapsed: Double
        var timestamp: Date
        var rate: Double

        func position(at date: Date, playing: Bool) -> Double {
            let advanced = elapsed + (playing ? date.timeIntervalSince(timestamp) * max(rate, 0) : 0)
            return duration > 0 ? min(max(advanced, 0), duration) : max(advanced, 0)
        }
    }

    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var appPID: pid_t?
    private(set) var artwork: NSImage?
    /// Called when playback starts or a new track begins while playing.
    @ObservationIgnored var onPlaybackStarted: (() -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var failures: [Date] = []
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var wasPlaying = false
    @ObservationIgnored private let log = Logger(subsystem: "io.github.broisnischal.forte", category: "nowplaying")

    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    private static let loader = """
        use DynaLoader;
        my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
        my $run = DynaLoader::dl_find_symbol($lib, "bs_now_playing_run") or die "missing entry point";
        DynaLoader::dl_install_xsub("main::run", $run);
        main::run();
        """

    private var helperURL: URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent("BSNowPlaying.framework/BSNowPlaying")
    }

    var appName: String? { appPID.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } }

    func start() {
        guard process == nil, let helperURL, FileManager.default.isExecutableFile(atPath: Self.perl.path),
              FileManager.default.fileExists(atPath: helperURL.path) else { return }
        stopping = false

        let process = Process()
        process.executableURL = Self.perl
        process.arguments = ["-e", Self.loader, helperURL.path]
        let stdout = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consume(data) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.helperExited(status: status) }
            }
        }
        do {
            try process.run()
            self.process = process
            self.input = stdin.fileHandleForWriting
        } catch {
            log.error("Now Playing helper failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        stopping = true
        try? input?.close() // The helper exits on end of input.
        input = nil
        process = nil
    }

    func togglePlayPause() {
        isPlaying.toggle() // Optimistic; the helper confirms.
        send("toggle")
    }

    func next() { send("next") }
    func previous() { send("previous") }
    func seek(to seconds: Double) { send("seek \(seconds)") }

    func activateApp() {
        guard let appPID else { return }
        NSRunningApplication(processIdentifier: appPID)?.activate()
    }

    private func send(_ command: String) {
        try? input?.write(contentsOf: Data((command + "\n").utf8))
    }

    private func helperExited(status: Int32) {
        process = nil
        input = nil
        guard !stopping else { return }
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard failures.count < 3 else {
            log.error("Now Playing helper keeps exiting (status \(status)); giving up")
            track = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(object) }
        }
    }

    private func apply(_ state: [String: Any]) {
        if let error = state["error"] as? String {
            log.error("Now Playing: \(error, privacy: .public)")
            return
        }
        if let encoded = state["artwork"] as? String {
            artwork = encoded.isEmpty ? nil : Data(base64Encoded: encoded).flatMap(NSImage.init(data:))
        }
        let playing = state["playing"] as? Bool ?? false
        let previousTitle = track?.title
        if playing != isPlaying { isPlaying = playing }
        defer {
            if playing, isPlaying, previousTitle != track?.title || !wasPlaying { onPlaybackStarted?() }
            wasPlaying = playing
        }
        let pid = (state["pid"] as? Int).flatMap { $0 > 0 ? pid_t($0) : nil }
        if pid != appPID { appPID = pid }

        guard let title = state["title"] as? String, !title.isEmpty else {
            if track != nil { track = nil }
            return
        }
        let newTrack = Track(
            title: title,
            artist: state["artist"] as? String ?? "",
            album: state["album"] as? String ?? "",
            duration: state["duration"] as? Double ?? 0,
            elapsed: state["elapsed"] as? Double ?? 0,
            timestamp: (state["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date(),
            rate: state["rate"] as? Double ?? (playing ? 1 : 0))
        if newTrack != track { track = newTrack }
    }
}
