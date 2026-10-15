import AppKit
import ForteKit
import SwiftUI

struct MixerTab: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        let apps = controller.mixerApps
        VStack(spacing: 10) {
            if controller.status != .running {
                Notice(symbol: "info.circle", text: "Turn on Forte to set volumes for individual apps.")
            }

            Card {
                SectionHeader(title: "APPS") {
                    if !controller.appVolumes.isEmpty {
                        Button("Reset All") { controller.resetAppVolumes() }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                if apps.isEmpty {
                    Text("Apps appear here when they use audio.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    VStack(spacing: 2) {
                        ForEach(apps) { app in
                            AppRow(app: app)
                            if app.id != apps.last?.id { Divider().opacity(0.5) }
                        }
                    }
                }
            }
            .disabled(controller.status != .running)

            Text("Apps play at 100% until you change them. Settings are remembered per app.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }
}

private struct AppRow: View {
    let app: AudioApp
    @Environment(AudioController.self) private var controller
    @Environment(MeterModel.self) private var meters

    var body: some View {
        let setting = controller.appVolume(app.id)
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                AppIcon(pid: app.pid)
                    .frame(width: 22, height: 22)
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                ActivityIndicator(playing: app.isPlaying, level: meters.appLevels[app.id])
                Spacer(minLength: 4)
                Text(setting.muted ? "Muted" : "\(Int((setting.volume * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(setting.isDefault ? .tertiary : .secondary)
            }
            HStack(spacing: 8) {
                Button {
                    controller.setMuted(!setting.muted, forApp: app.id)
                } label: {
                    Image(systemName: setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 18)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(setting.muted ? Color.red : .secondary)
                .help(setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
                .accessibilityLabel(setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)")

                FillSlider(value: Binding(get: { setting.volume }, set: { controller.setVolume($0, forApp: app.id) }),
                           range: 0...AudioController.maxAppVolume, origin: nil, resetValue: 1, step: 0.02,
                           fill: setting.muted ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Theme.accent),
                           mark: 1, label: "\(app.name) volume") { "\(Int(($0 * 100).rounded())) percent" }
                    .opacity(setting.muted ? 0.5 : 1)
            }
        }
        .padding(.vertical, 5)
    }
}

/// Live level for apps with their own tap; a gentle pulse for other apps that are playing.
private struct ActivityIndicator: View {
    let playing: Bool
    let level: Float?

    var body: some View {
        if let level {
            let fraction = CGFloat(min(max((level + 50) / 50, 0), 1))
            Capsule().fill(Theme.track)
                .frame(width: 28, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.green).frame(width: 28 * fraction, height: 4)
                }
                .accessibilityHidden(true)
        } else if playing {
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
                .symbolEffect(.variableColor.iterative, isActive: true)
                .accessibilityLabel("Playing")
        }
    }
}

private struct AppIcon: View {
    let pid: pid_t

    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon).resizable().interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .foregroundStyle(.secondary)
                .padding(2)
        }
    }
}

struct Notice: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
    }
}
