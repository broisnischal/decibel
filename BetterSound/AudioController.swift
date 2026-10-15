import AppKit
import BetterSoundKit
import CoreAudio
import Observation
import ServiceManagement
import os

/// A per-app mixer setting. Apps without one play at 100 %.
struct AppVolume: Codable, Equatable {
    var volume: Float = 1
    var muted = false
    var isDefault: Bool { volume == 1 && !muted }
    var gain: Float { muted ? 0 : volume }
}

struct DeviceInfo: Identifiable, Equatable {
    let device: AudioDevice
    let channels: Int
    let sampleRate: Double
    let sampleRates: [Double]
    let canSetSampleRate: Bool
    var id: AudioObjectID { device.id }
}

enum PanelTab: String, CaseIterable, Identifiable {
    case sound = "Sound", mixer = "Mixer", equalizer = "EQ", devices = "Devices"
    var id: String { rawValue }
}

/// App state: persisted sound settings, the live audio route, system volume, the per-app mixer and devices.
@MainActor @Observable
final class AudioController {
    enum Status: Equatable {
        case off, starting, running, needsPermission
        case failed(String)
    }

    enum VolumeMode: Equatable {
        /// The device's own volume (what the volume keys change).
        case hardware
        /// The device has no volume control (e.g. HDMI), so BetterSound scales its output instead.
        case software
        /// No hardware control and BetterSound is off.
        case unavailable
    }

    static let maxBoostDB: Float = 20 * log10(8) // 800 %
    static let maxAppVolume: Float = 2

    // MARK: Persisted sound settings (each pushes straight to the real-time kernel)

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Key.enabled)
            isEnabled ? start() : stop()
        }
    }

    var boostDB: Float {
        didSet {
            processor?.setBoost(boostDB)
            defaults.set(boostDB, forKey: Key.boost)
        }
    }

    var eqEnabled: Bool {
        didSet {
            processor?.setEQEnabled(eqEnabled)
            defaults.set(eqEnabled, forKey: Key.eqEnabled)
        }
    }

    var eqGains: [Float] {
        didSet {
            for band in eqGains.indices where band >= oldValue.count || eqGains[band] != oldValue[band] {
                processor?.setEQGain(eqGains[band], band: band)
            }
            defaults.set(eqGains, forKey: Key.eqGains)
        }
    }

    var bassDB: Float {
        didSet {
            processor?.setBass(bassDB)
            defaults.set(bassDB, forKey: Key.bass)
        }
    }

    var trebleDB: Float {
        didSet {
            processor?.setTreble(trebleDB)
            defaults.set(trebleDB, forKey: Key.treble)
        }
    }

    var balance: Float {
        didSet {
            processor?.setBalance(balance)
            defaults.set(balance, forKey: Key.balance)
        }
    }

    var width: Float {
        didSet {
            processor?.setWidth(width)
            defaults.set(width, forKey: Key.width)
        }
    }

    private(set) var customPresets: [EQPreset] {
        didSet { defaults.set(try? JSONEncoder().encode(customPresets), forKey: Key.customPresets) }
    }

    private(set) var appVolumes: [String: AppVolume] {
        didSet { defaults.set(try? JSONEncoder().encode(appVolumes), forKey: Key.appVolumes) }
    }

    /// Software volume per device UID, for outputs without hardware volume.
    @ObservationIgnored private var softwareVolumes: [String: AppVolume] {
        didSet { defaults.set(try? JSONEncoder().encode(softwareVolumes), forKey: Key.softwareVolumes) }
    }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log.error("Launch at login: \(error.localizedDescription, privacy: .public)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    var activeTab: PanelTab {
        didSet {
            defaults.set(activeTab.rawValue, forKey: Key.tab)
            updatePolling()
        }
    }

    // MARK: Live state

    private(set) var status: Status = .off {
        didSet {
            status == .needsPermission ? watchPermission() : permissionTimer?.invalidate()
            if (status == .running) != (oldValue == .running) { refreshOutputVolume() }
        }
    }

    private(set) var outputDevice: AudioDevice?
    private(set) var inputDevice: AudioDevice?
    private(set) var outputDevices: [DeviceInfo] = []
    private(set) var inputDevices: [DeviceInfo] = []
    private(set) var sampleRate: Double = 48_000

    private(set) var outputVolume: Float = 1
    private(set) var outputMuted = false
    private(set) var outputVolumeMode: VolumeMode = .hardware
    private(set) var inputVolume: Float?
    private(set) var inputMuted = false
    private(set) var canMuteInput = false

    /// Every app the HAL knows about (refreshed on process changes, and every second while the mixer is open).
    private(set) var apps: [AudioApp] = []

    var panelVisible = false {
        didSet {
            meters.isVisible = panelVisible
            updatePolling()
        }
    }

    let meters = MeterModel()

    @ObservationIgnored private var router: SystemAudioRouter? {
        didSet { meters.router = router }
    }
    private var processor: SoundProcessor? { router?.processor }
    @ObservationIgnored private var systemListeners: [AudioPropertyListener] = []
    @ObservationIgnored private var outputListeners: [AudioPropertyListener] = []
    @ObservationIgnored private var inputListeners: [AudioPropertyListener] = []
    @ObservationIgnored private var routeListeners: [AudioPropertyListener] = []
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var restartWork: DispatchWorkItem?
    @ObservationIgnored private var appsWork: DispatchWorkItem?
    @ObservationIgnored private var diagnosticsTimer: Timer?
    @ObservationIgnored private var planTimer: Timer?
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var appsTimer: Timer?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let log = Logger(subsystem: "com.bettersound.mac", category: "controller")

    private enum Key {
        static let enabled = "enabled", boost = "boostDB", eqEnabled = "eqEnabled", eqGains = "eqGains"
        static let bass = "bassDB", treble = "trebleDB", balance = "balance", width = "width"
        static let customPresets = "customPresets", appVolumes = "appVolumes", softwareVolumes = "softwareVolumes"
        static let tab = "tab"
    }

    init() {
        defaults.register(defaults: [Key.enabled: true, Key.eqEnabled: true, Key.width: Float(1)])
        let store = UserDefaults.standard
        func decode<T: Decodable>(_ key: String, _: T.Type) -> T? {
            store.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        isEnabled = defaults.bool(forKey: Key.enabled)
        boostDB = min(max(defaults.float(forKey: Key.boost), 0), Self.maxBoostDB)
        eqEnabled = defaults.bool(forKey: Key.eqEnabled)
        let storedGains = defaults.array(forKey: Key.eqGains) as? [Float] ?? []
        eqGains = storedGains.count == Equalizer.bandCount ? storedGains : EQPreset.flat.gains
        bassDB = defaults.float(forKey: Key.bass)
        trebleDB = defaults.float(forKey: Key.treble)
        balance = defaults.float(forKey: Key.balance)
        width = defaults.float(forKey: Key.width)
        customPresets = decode(Key.customPresets, [EQPreset].self) ?? []
        appVolumes = decode(Key.appVolumes, [String: AppVolume].self) ?? [:]
        softwareVolumes = decode(Key.softwareVolumes, [String: AppVolume].self) ?? [:]
        launchAtLogin = SMAppService.mainApp.status == .enabled
        activeTab = defaults.string(forKey: Key.tab).flatMap(PanelTab.init(rawValue:)) ?? .sound
    }

    private func settings(for device: AudioDevice) -> SoundSettings {
        var s = SoundSettings()
        s.boostDB = boostDB
        s.eqEnabled = eqEnabled
        s.eqGains = eqGains
        s.bassDB = bassDB
        s.trebleDB = trebleDB
        s.balance = balance
        s.width = width
        s.outputGain = device.canSetVolume(.output) ? 1 : softwareGain(softwareVolumes[device.uid] ?? AppVolume())
        return s
    }

    // MARK: Lifecycle

    func activate() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        systemListeners = [
            try? AudioPropertyListener(object: system, selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                self?.refreshDevices()
                self?.scheduleRestart()
            },
            try? AudioPropertyListener(object: system, selector: kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
                self?.refreshDevices()
            },
            try? AudioPropertyListener(object: system, selector: kAudioHardwarePropertyDevices) { [weak self] in
                self?.refreshDevices()
            },
            try? AudioPropertyListener(object: system, selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
                self?.scheduleAppsRefresh()
            },
        ].compactMap { $0 }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRestart() }
        }

        refreshDevices()
        apps = AudioApps.current()
        if isEnabled { start() }
        if defaults.bool(forKey: "diagnostics") { startDiagnostics() }
    }

    func shutdown() {
        startTask?.cancel()
        router = nil
    }

    private func start() {
        startTask?.cancel()
        status = .starting
        startTask = Task { [weak self] in
            let permission = AudioCapturePermission.status
            self?.log.notice("System audio permission: \(String(describing: permission), privacy: .public)")
            switch permission {
            case .authorized: break
            case .denied:
                self?.status = .needsPermission
                return
            case .unknown:
                guard await AudioCapturePermission.request() else {
                    self?.status = .needsPermission
                    return
                }
            }
            guard let self, !Task.isCancelled, self.isEnabled else { return }
            self.buildRoute()
        }
    }

    private func stop() {
        startTask?.cancel()
        restartWork?.cancel()
        router = nil
        routeListeners = []
        planTimer?.invalidate()
        status = .off
    }

    func retry() {
        guard isEnabled else { isEnabled = true; return }
        start()
    }

    private func buildRoute() {
        router = nil // Tear down first: only one set of taps may mute the system at a time.
        routeListeners = []
        planTimer?.invalidate()
        do {
            let device = try AudioDevice.defaultOutput()
            apps = AudioApps.current()
            let plan = desiredPlan(for: device)
            let router = try SystemAudioRouter(outputDevice: device, settings: settings(for: device), plan: plan,
                                               appGains: appVolumes.mapValues(\.gain))
            self.router = router
            outputDevice = device
            sampleRate = router.sampleRate
            status = .running
            routeListeners = [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive].compactMap {
                try? AudioPropertyListener(object: device.id, selector: $0) { [weak self] in self?.scheduleRestart() }
            }
            if device.hasInput { watchLoopbackReaders() }
        } catch {
            log.error("Route failed: \(String(describing: error), privacy: .public)")
            status = .failed(String(describing: error))
        }
    }

    /// Device changes arrive in bursts; rebuild once they settle.
    private func scheduleRestart() {
        guard isEnabled else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled, self.status != .needsPermission else { return }
                self.buildRoute()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Picks up a grant made in System Settings without needing a manual retry.
    private func watchPermission() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AudioCapturePermission.status == .authorized else { return }
                self.permissionTimer?.invalidate()
                if self.isEnabled { self.start() }
            }
        }
    }

    /// A loopback output's companion app may start or stop recording it at any time; re-route when that changes.
    private func watchLoopbackReaders() {
        planTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileRoute() }
        }
    }

    func openPermissionSettings() {
        NSWorkspace.shared.open(AudioCapturePermission.settingsURL)
    }

    /// `-diagnostics YES` logs signal flow once a second (only meaningful while the panel is closed).
    private func startDiagnostics() {
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let m = self.processor?.readMeters() else { return }
                if Int(Date().timeIntervalSince1970) % 5 == 0 {
                    self.apps = AudioApps.current()
                    self.logApps()
                }
                let db = { (x: Float) in String(format: "%.1f", 20 * log10(max(x, 1e-6))) }
                self.log.notice("""
                    renders=\(m.renderCount, privacy: .public) \
                    in=\(db(m.input.left), privacy: .public)/\(db(m.input.right), privacy: .public) dBFS \
                    out=\(db(m.output.left), privacy: .public)/\(db(m.output.right), privacy: .public) dBFS \
                    gr=\(m.gainReduction, privacy: .public) dB
                    """)
            }
        }
    }

    private func updatePolling() {
        let mixerOpen = panelVisible && activeTab == .mixer
        if mixerOpen, appsTimer == nil {
            apps = AudioApps.current()
            appsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshApps() }
            }
        } else if !mixerOpen {
            appsTimer?.invalidate()
            appsTimer = nil
        }
        if panelVisible { refreshDevices() }
    }

    // MARK: Devices

    private func refreshDevices() {
        func info(_ device: AudioDevice, _ scope: AudioDevice.Scope) -> DeviceInfo {
            DeviceInfo(device: device, channels: device.channelCount(scope),
                       sampleRate: (try? device.nominalSampleRate()) ?? 0,
                       sampleRates: device.availableSampleRates, canSetSampleRate: device.canSetSampleRate)
        }
        outputDevices = AudioDevice.devices(.output).map { info($0, .output) }
        inputDevices = AudioDevice.devices(.input).map { info($0, .input) }

        let output = try? AudioDevice.default(.output)
        if output != outputDevice || outputListeners.isEmpty {
            outputDevice = output
            outputListeners = output.map { volumeListeners($0, .output) { [weak self] in self?.refreshOutputVolume() } } ?? []
        }
        let input = try? AudioDevice.default(.input)
        if input != inputDevice || inputListeners.isEmpty {
            inputDevice = input
            inputListeners = input.map { volumeListeners($0, .input) { [weak self] in self?.refreshInputVolume() } } ?? []
        }
        refreshOutputVolume()
        refreshInputVolume()
    }

    private func volumeListeners(_ device: AudioDevice, _ scope: AudioDevice.Scope,
                                 handler: @escaping () -> Void) -> [AudioPropertyListener] {
        AudioDevice.volumeSelectors.compactMap {
            try? AudioPropertyListener(object: device.id, selector: $0,
                                       scope: scope == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput,
                                       handler: handler)
        }
    }

    func select(_ device: AudioDevice, as scope: AudioDevice.Scope) {
        do { try device.makeDefault(scope) } catch { log.error("Select device: \(String(describing: error), privacy: .public)") }
    }

    func setSampleRate(_ rate: Double, for device: AudioDevice) {
        do { try device.setNominalSampleRate(rate) } catch { log.error("Sample rate: \(String(describing: error), privacy: .public)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
    }

    // MARK: System volume

    private func refreshOutputVolume() {
        guard let device = outputDevice else {
            outputVolumeMode = .unavailable
            return
        }
        if device.canSetVolume(.output) {
            outputVolumeMode = .hardware
            outputVolume = device.volume(.output) ?? 1
            outputMuted = device.isMuted(.output) ?? false
        } else if router != nil {
            outputVolumeMode = .software
            let stored = softwareVolumes[device.uid] ?? AppVolume()
            outputVolume = stored.volume
            outputMuted = stored.muted
        } else {
            outputVolumeMode = .unavailable
            outputVolume = 1
            outputMuted = false
        }
    }

    /// Perceptual taper for software volume: 0.5 on the slider is -20 dB.
    private func softwareGain(_ setting: AppVolume) -> Float {
        setting.muted || setting.volume <= 0 ? 0 : pow(10, (setting.volume - 1) * 2)
    }

    func setOutputVolume(_ volume: Float) {
        guard let device = outputDevice else { return }
        outputVolume = volume
        switch outputVolumeMode {
        case .hardware:
            try? device.setVolume(volume, .output)
            if outputMuted, volume > 0 { setOutputMuted(false) }
        case .software:
            outputMuted = outputMuted && volume == 0
            storeSoftwareVolume(device)
        case .unavailable:
            break
        }
    }

    func setOutputMuted(_ muted: Bool) {
        guard let device = outputDevice else { return }
        outputMuted = muted
        switch outputVolumeMode {
        case .hardware where device.canMute(.output): try? device.setMuted(muted, .output)
        case .hardware: try? device.setVolume(muted ? 0 : max(outputVolume, 0.25), .output)
        case .software: storeSoftwareVolume(device)
        case .unavailable: break
        }
    }

    private func storeSoftwareVolume(_ device: AudioDevice) {
        let setting = AppVolume(volume: outputVolume, muted: outputMuted)
        softwareVolumes[device.uid] = setting
        processor?.setOutputGain(softwareGain(setting))
    }

    private func refreshInputVolume() {
        guard let device = inputDevice else {
            inputVolume = nil
            return
        }
        inputVolume = device.canSetVolume(.input) ? device.volume(.input) : nil
        inputMuted = device.isMuted(.input) ?? false
        canMuteInput = device.canMute(.input)
    }

    func setInputVolume(_ volume: Float) {
        inputVolume = volume
        try? inputDevice?.setVolume(volume, .input)
    }

    func setInputMuted(_ muted: Bool) {
        inputMuted = muted
        try? inputDevice?.setMuted(muted, .input)
    }

    // MARK: Per-app mixer

    /// Apps worth showing: regular apps with an audio connection, anything playing, and anything with a setting.
    var mixerApps: [AudioApp] {
        apps.filter { $0.isRegularApp || $0.isPlaying || appVolumes[$0.id] != nil }
    }

    func appVolume(_ appID: String) -> AppVolume { appVolumes[appID] ?? AppVolume() }

    func setVolume(_ volume: Float, forApp appID: String) { updateApp(appID) { $0.volume = volume } }

    func setMuted(_ muted: Bool, forApp appID: String) { updateApp(appID) { $0.muted = muted } }

    func resetAppVolumes() {
        for appID in appVolumes.keys { router?.setGain(1, forApp: appID) }
        appVolumes = [:]
    }

    private func updateApp(_ appID: String, _ change: (inout AppVolume) -> Void) {
        var setting = appVolume(appID)
        change(&setting)
        appVolumes[appID] = setting.isDefault ? nil : setting
        if let router, router.mixes(appID) {
            router.setGain(setting.gain, forApp: appID)
        } else if !setting.isDefault {
            reconcileRoute() // The app needs its own tap.
        }
    }

    private func scheduleAppsRefresh() {
        appsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshApps() }
        }
        appsWork = work
        // Immediately (coalescing a burst): a new process of a mixed app plays through the shared tap at 100 %
        // until it is moved to its own.
        DispatchQueue.main.async(execute: work)
    }

    private func refreshApps() {
        apps = AudioApps.current()
        reconcileRoute()
    }

    private func logApps() {
        guard diagnosticsTimer != nil else { return }
        let summary = apps.map { "\($0.id)\($0.isPlaying ? "▶" : "")\(router?.mixes($0.id) == true ? "[mixed]" : "")" }
        log.notice("apps: \(summary.joined(separator: ", "), privacy: .public)")
    }

    /// Apps with a custom volume get their own tap. Apps already mixed keep theirs (even with no processes left)
    /// so that process churn only updates taps in place instead of re-routing.
    private func desiredPlan(for device: AudioDevice) -> RoutePlan {
        var plan = RoutePlan()
        plan.excluded = device.hasInput ? AudioProcesses.readers(of: device.id) : []
        let processes = Dictionary(apps.map { ($0.id, $0.processes) }, uniquingKeysWith: +)
        let current = router?.plan.appTaps.map(\.appID) ?? []
        let wanted = Set(current).union(appVolumes.keys.filter { processes[$0] != nil })
        plan.appTaps = wanted
            .sorted { (current.contains($0) ? 0 : 1, $0) < (current.contains($1) ? 0 : 1, $1) } // Existing taps keep their order.
            .prefix(RoutePlan.maxAppTaps)
            .map { RoutePlan.AppTap(appID: $0, processes: (processes[$0] ?? []).filter { !plan.excluded.contains($0) }) }
            .filter { !$0.processes.isEmpty || current.contains($0.appID) }
        return plan
    }

    private func reconcileRoute() {
        guard isEnabled, status == .running, let router else { return }
        let desired = desiredPlan(for: router.outputDevice)
        if desired != router.plan, !router.update(to: desired) { scheduleRestart() }
    }

    // MARK: Presets

    var allPresets: [EQPreset] { EQPreset.builtIns + customPresets }

    /// The preset whose curve matches the current EQ exactly, if any.
    var currentPreset: EQPreset? { allPresets.first { $0.gains == eqGains } }

    func apply(_ preset: EQPreset) {
        eqGains = preset.gains
        eqEnabled = true
    }

    /// Flat bands and centred tone controls.
    func resetEqualizer() {
        eqGains = EQPreset.flat.gains
        bassDB = 0
        trebleDB = 0
    }

    var isEqualizerFlat: Bool { eqGains == EQPreset.flat.gains && bassDB == 0 && trebleDB == 0 }

    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        customPresets.removeAll { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        customPresets.append(EQPreset(name: trimmed, gains: eqGains))
    }

    func delete(_ preset: EQPreset) {
        customPresets.removeAll { $0.id == preset.id }
    }
}
