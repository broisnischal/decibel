import AppKit
import DecibelKit
import SwiftUI

struct MainPage: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(title: "Decibel") {
                if let state = stateText {
                    Text(state)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help(controller.status == .standby
                              ? "Idle: Decibel starts processing when sound plays and an effect is on, so it isn't recording the rest of the time."
                              : "Processing your Mac's sound.")
                }
                Toggle("Sound processing", isOn: $controller.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(controller.isEnabled ? "Turn off boost, EQ and per-app volume" : "Turn on boost, EQ and per-app volume")
            }
            if let banner = StatusBanner(status: controller.status) { banner }

            NowPlayingCard()
            SoundSection()
            PanelDivider()
            OutputSection()
            PanelDivider()
            AppsSection()
            PanelDivider()
            PageLinks()
            PanelDivider()
            FooterRows()
        }
    }
}

private extension MainPage {
    var stateText: String? {
        switch controller.status {
        case .running: "Active"
        case .standby: "Standby"
        case .starting: "Starting…"
        default: nil
        }
    }
}

// MARK: - Now Playing

private struct NowPlayingCard: View {
    @Environment(NowPlaying.self) private var nowPlaying

    var body: some View {
        if let track = nowPlaying.track {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button { nowPlaying.activateApp() } label: { Artwork(image: nowPlaying.artwork, pid: nowPlaying.appPID) }
                        .buttonStyle(.plain)
                        .help(nowPlaying.appName.map { "Open \($0)" } ?? "")

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle(track))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 0) {
                        IconButton(symbol: "backward.fill", size: 12, help: "Previous") { nowPlaying.previous() }
                        IconButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 16,
                                   help: nowPlaying.isPlaying ? "Pause" : "Play") { nowPlaying.togglePlayPause() }
                        IconButton(symbol: "forward.fill", size: 12, help: "Next") { nowPlaying.next() }
                    }
                }
                if track.duration > 0 {
                    PlaybackProgress(track: track, playing: nowPlaying.isPlaying)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, Metrics.inset - 4)
            .padding(.bottom, 8)
            .transition(.opacity)
        }
    }

    private func subtitle(_ track: NowPlaying.Track) -> String {
        [track.artist, nowPlaying.appName ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct Artwork: View {
    let image: NSImage?
    let pid: pid_t?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let pid, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                Image(nsImage: icon).resizable().padding(5)
                    .background(Color.primary.opacity(0.08))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.08))
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct PlaybackProgress: View {
    let track: NowPlaying.Track
    let playing: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = track.position(at: context.date, playing: playing)
            HStack(spacing: 8) {
                Text(Self.time(position))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(Color.primary.opacity(0.55))
                            .frame(width: geo.size.width * CGFloat(position / track.duration))
                    }
                }
                .frame(height: 3)
                Text("-" + Self.time(track.duration - position))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Self.time(track.position(at: .now, playing: playing))) of \(Self.time(track.duration))")
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0).rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Volume and boost

private struct SoundSection: View {
    @Environment(AudioController.self) private var controller
    @Environment(MeterModel.self) private var meters

    var body: some View {
        @Bindable var controller = controller
        let available = controller.outputVolumeMode != .unavailable
        let shown = controller.outputMuted ? 0 : controller.outputVolume
        let limiting = meters.gainReduction > 0.5

        VStack(spacing: 6) {
            SliderRow {
                IconButton(symbol: VolumeSymbol.name(volume: controller.outputVolume, muted: controller.outputMuted),
                           tint: controller.outputMuted ? .secondary : .primary,
                           help: controller.outputMuted ? "Unmute" : "Mute") {
                    controller.setOutputMuted(!controller.outputMuted)
                }
                .disabled(!available)
            } slider: {
                SlimSlider(value: Binding(get: { shown }, set: { controller.setOutputVolume($0) }),
                           label: "Volume", valueText: percent)
            } value: {
                available ? (controller.outputMuted ? "Muted" : percent(shown)) : "Fixed"
            }
            .disabled(!available)
            .help(available ? (controller.outputVolumeMode == .software ? "Software volume (this device has no volume control)" : "")
                            : "This device has no volume control. Turn on Decibel to control it.")

            SliderRow {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(limiting ? Color.orange : .secondary)
                    .frame(width: 24, height: 24)
                    .help(limiting ? "Boost: the limiter is keeping it from clipping" : "Boost: amplify beyond 100%")
            } slider: {
                SlimSlider(value: $controller.boostDB, range: 0...AudioController.maxBoostDB, step: 0.25, tint: .orange,
                           label: "Boost", valueText: { _ in boostText })
            } value: {
                boostText
            }
            .disabled(!controller.isEnabled)
        }
        .padding(.vertical, 2)
        .animation(.easeOut(duration: 0.2), value: limiting)
    }

    private var boostText: String {
        let db = controller.boostDB
        return db < 0.05 ? "Off" : "\(Int((pow(10, db / 20) * 100).rounded()))%"
    }
}

// MARK: - Output devices

private struct OutputSection: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Output")
            ForEach(controller.outputDevices) { info in
                let selected = info.id == controller.outputDevice?.id
                MenuRow {
                    controller.select(info.device, as: .output)
                } content: {
                    CircleIcon(symbol: info.device.kind.symbol, selected: selected, size: 24)
                    Text(info.device.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

// MARK: - Per-app volume

private struct AppsSection: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        let apps = controller.mixerApps
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title: "Apps") {
                if !controller.appVolumes.isEmpty {
                    Button("Reset") { controller.resetAppVolumes() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                        .help("Return every app to 100%")
                }
            }
            if !controller.isEnabled {
                hint("Turn on Decibel to set each app's volume.")
            } else if apps.isEmpty {
                hint("Apps appear here when they play sound.")
            } else if apps.count > 6 {
                ScrollView { rows(apps) }.frame(height: 6 * 30)
            } else {
                rows(apps)
            }
        }
    }

    private func rows(_ apps: [AudioApp]) -> some View {
        VStack(spacing: 2) {
            ForEach(apps) { AppRow(app: $0) }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, 4)
    }
}

private struct AppRow: View {
    let app: AudioApp
    @Environment(AudioController.self) private var controller
    @Environment(MeterModel.self) private var meters

    var body: some View {
        let setting = controller.appVolume(app.id)
        HStack(spacing: 8) {
            Button {
                controller.setMuted(!setting.muted, forApp: app.id)
            } label: {
                icon
                    .frame(width: 20, height: 20)
                    .opacity(setting.muted ? 0.4 : 1)
                    .overlay(alignment: .bottomTrailing) { badge(muted: setting.muted) }
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .accessibilityLabel(setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)")

            Text(app.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)
                .help(app.name)

            SlimSlider(value: Binding(get: { setting.volume }, set: { controller.setVolume($0, forApp: app.id) }),
                       range: 0...AudioController.maxAppVolume, step: 0.01, detent: 1,
                       tint: setting.muted ? .secondary : .accentColor,
                       label: "\(app.name) volume", valueText: percent)

            Text(setting.muted ? "Muted" : percent(setting.volume))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(setting.isDefault ? .tertiary : .secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.leading, Metrics.inset - 4)
        .padding(.trailing, Metrics.inset)
        .frame(height: 28)
        .contextMenu {
            Button(setting.muted ? "Unmute" : "Mute") { controller.setMuted(!setting.muted, forApp: app.id) }
            Button("Reset to 100%") {
                controller.setMuted(false, forApp: app.id)
                controller.setVolume(1, forApp: app.id)
            }
            .disabled(setting.isDefault)
        }
    }

    @ViewBuilder private var icon: some View {
        if app.id == AudioApps.systemSoundsID {
            Image(systemName: "bell.fill")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.1)))
        } else {
            AppIcon(pid: app.pid)
        }
    }

    /// Red slash when muted; a green dot while the app is making sound.
    @ViewBuilder private func badge(muted: Bool) -> some View {
        if muted {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(.white)
                .padding(2.5)
                .background(Circle().fill(Color.red))
                .offset(x: 3, y: 3)
        } else if app.isPlaying || (meters.appLevels[app.id] ?? -120) > -60 {
            Circle()
                .fill(Color.green)
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                .frame(width: 8, height: 8)
                .offset(x: 2, y: 2)
                .accessibilityLabel("Playing")
        }
    }
}

// MARK: - Pages and footer

private struct PageLinks: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        VStack(spacing: 0) {
            link(.equalizer, "Equalizer", "slider.vertical.3",
                 detail: controller.eqEnabled ? (controller.currentPreset?.name ?? "Custom") : "Off")
            link(.effects, "Stereo & Levels", "dial.medium.fill", detail: stereoSummary)
            link(.microphone, "Microphone", controller.inputMuted ? "mic.slash.fill" : "mic.fill",
                 detail: controller.inputMuted ? "Muted" : (controller.inputDevice?.name ?? "None"))
            link(.devices, "Audio Devices", "hifispeaker.2.fill", detail: "")
        }
    }

    private func link(_ page: PanelPage, _ title: String, _ symbol: String, detail: String) -> some View {
        MenuRow {
            controller.page = page
        } content: {
            CircleIcon(symbol: symbol, size: 24)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var stereoSummary: String {
        let b = Int((abs(controller.balance) * 100).rounded())
        let balance = b == 0 ? "Centered" : (controller.balance < 0 ? "L \(b)" : "R \(b)")
        let width = Int((controller.width * 100).rounded())
        return width == 100 ? balance : "\(balance) · \(width)%"
    }
}

private struct FooterRows: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            HStack {
                Text("Open at Login").font(.system(size: 13))
                Spacer()
                Toggle("Open at Login", isOn: $controller.launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .frame(minHeight: 30)
            .padding(.horizontal, Metrics.inset)

            MenuRow {
                NSApp.terminate(nil)
            } content: {
                Text("Quit Decibel").font(.system(size: 13))
                Spacer()
                Text("⌘Q").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .keyboardShortcut("q")
        }
    }
}
