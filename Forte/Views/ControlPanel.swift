import AppKit
import ForteKit
import SwiftUI

struct ControlPanel: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            HeaderView()
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            MasterVolumeRow()
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            TabBar(selection: $controller.activeTab)
                .padding(.horizontal, 12)
            .padding(.bottom, 10)

            if let banner = StatusBanner(status: controller.status) {
                banner.padding(.horizontal, 12).padding(.bottom, 10)
            }

            ScrollView {
                Group {
                    switch controller.activeTab {
                    case .sound: SoundTab()
                    case .mixer: MixerTab()
                    case .equalizer: EqualizerTab()
                    case .devices: DevicesTab()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.automatic)
            .frame(height: 404)

            Divider().padding(.top, 6)
            FooterView()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 372)
        .background(WindowVisibilityReader { controller.panelVisible = $0 })
    }
}

// MARK: - Header

private struct HeaderView: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent, Color(red: 0.95, green: 0.32, blue: 0.2)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("Forte").font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("Sound processing", isOn: $controller.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.accent)
                .help(controller.isEnabled ? "Turn off boost, EQ and the mixer" : "Turn on boost, EQ and the mixer")
        }
    }

    private var subtitle: String {
        switch controller.status {
        case .running:
            let khz = (controller.sampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))
            return "Processing · \(khz) kHz"
        case .starting: return "Starting…"
        case .off: return "Processing off"
        case .needsPermission: return "Needs permission"
        case .failed: return "Couldn't start"
        }
    }
}

// MARK: - Master volume

private struct MasterVolumeRow: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        let available = controller.outputVolumeMode != .unavailable
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    controller.setOutputMuted(!controller.outputMuted)
                } label: {
                    Image(systemName: VolumeSymbol.name(volume: controller.outputVolume, muted: controller.outputMuted))
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(controller.outputMuted ? .secondary : .primary)
                .help(controller.outputMuted ? "Unmute" : "Mute")
                .accessibilityLabel(controller.outputMuted ? "Unmute output" : "Mute output")
                .disabled(!available)

                FillSlider(value: Binding(get: { controller.outputMuted ? 0 : controller.outputVolume },
                                          set: { controller.setOutputVolume($0) }),
                           range: 0...1, origin: nil, resetValue: nil, step: 1.0 / 64,
                           fill: Color.primary.opacity(0.75), label: "Output volume") { "\(Int(($0 * 100).rounded())) percent" }
                    .disabled(!available)

                Text(available ? "\(Int(((controller.outputMuted ? 0 : controller.outputVolume) * 100).rounded()))%" : "—")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
            HStack(spacing: 4) {
                Image(systemName: controller.outputDevice?.kind.symbol ?? "speaker.wave.2")
                Text(controller.outputDevice?.name ?? "No output device").lineLimit(1)
                if controller.outputVolumeMode == .software {
                    Text("· software volume").foregroundStyle(.tertiary)
                } else if controller.outputVolumeMode == .unavailable {
                    Text("· fixed volume").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.leading, 30)
            .help(controller.outputVolumeMode == .unavailable
                  ? "This device has no volume control. Turn on Forte to control it in software." : "")
        }
        .opacity(available ? 1 : 0.6)
    }
}

enum VolumeSymbol {
    static func name(volume: Float, muted: Bool) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        return volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

extension AudioDevice.Kind {
    var symbol: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .bluetooth: "headphones"
        case .usb: "cable.connector"
        case .airPlay: "airplayaudio"
        case .display: "display"
        case .virtual: "point.3.connected.trianglepath.dotted"
        case .other: "hifispeaker"
        }
    }
}

// MARK: - Status

private struct StatusBanner: View {
    let message: String
    let actionTitle: String
    let action: (AudioController) -> Void
    let tint: Color

    init?(status: AudioController.Status) {
        switch status {
        case .needsPermission:
            message = "Allow Forte under System Audio Recording so it can process your Mac's sound."
            actionTitle = "Open Settings"
            action = { $0.openPermissionSettings() }
            tint = .orange
        case .failed(let error):
            message = error
            actionTitle = "Retry"
            action = { $0.retry() }
            tint = .red
        default:
            return nil
        }
    }

    @Environment(AudioController.self) private var controller

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tint)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(actionTitle) { action(controller) }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.12)))
    }
}

// MARK: - Footer

private struct FooterView: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        HStack {
            Toggle("Open at Login", isOn: $controller.launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .controlSize(.small)
        }
    }
}

/// Reports whether the hosting window is on screen, so meters and the mixer only poll while visible.
private struct WindowVisibilityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Tracker(onChange: onChange) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Tracker)?.onChange = onChange }

    final class Tracker: NSView {
        var onChange: (Bool) -> Void
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return onChange(false) }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            onChange(window?.occlusionState.contains(.visible) ?? false)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
