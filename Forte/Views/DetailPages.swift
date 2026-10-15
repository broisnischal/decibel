import ForteKit
import SwiftUI

// MARK: - Stereo & Levels

struct EffectsPage: View {
    @Environment(AudioController.self) private var controller
    @Environment(MeterModel.self) private var meters

    var body: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(title: "Stereo & Levels", back: { controller.page = .main }) { EmptyView() }

            SectionLabel(title: "Output Level") {
                Text(meters.gainReduction > 0.1 ? String(format: "Limiting −%.1f dB", meters.gainReduction) : "Limiter ready")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(meters.gainReduction > 0.1 ? Color.orange : Color.secondary)
            }
            VStack(spacing: 6) {
                meter("L", 0)
                meter("R", 1)
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.bottom, 4)

            PanelDivider()

            VStack(spacing: 12) {
                row("Balance", value: balanceText) {
                    HStack(spacing: 6) {
                        Text("L").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        Slider(value: $controller.balance.snapping(to: 0, within: 0.04, step: 0.01), in: -1...1) { Text("Balance") }
                            .labelsHidden()
                            .controlSize(.small)
                        Text("R").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                } reset: { controller.balance = 0 }

                row("Width", value: percent(controller.width)) {
                    Slider(value: $controller.width.snapping(to: 1, within: 0.05, step: 0.01), in: 0...2) { Text("Stereo width") }
                        .labelsHidden()
                        .controlSize(.small)
                } reset: { controller.width = 1 }
            }
            .padding(.horizontal, Metrics.inset)

            Text("Width 0% is mono; above 100% widens the stereo image.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Metrics.inset)
                .padding(.top, 10)
        }
        .disabled(!controller.isEnabled)
    }

    private func meter(_ label: String, _ channel: Int) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 10)
            PeakMeter(level: meters.output[channel], hold: meters.peakHold[channel])
        }
    }

    private func row<S: View>(_ title: String, value: String, @ViewBuilder slider: () -> S, reset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(value).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            slider()
        }
        .contextMenu { Button("Reset", action: reset) }
    }

    private var balanceText: String {
        let b = Int((abs(controller.balance) * 100).rounded())
        return b == 0 ? "Centered" : (controller.balance < 0 ? "Left \(b)%" : "Right \(b)%")
    }
}

// MARK: - Microphone

struct MicrophonePage: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(title: "Microphone", back: { controller.page = .main }) { EmptyView() }

            if let volume = controller.inputVolume {
                SliderRow {
                    IconButton(symbol: controller.inputMuted ? "mic.slash.fill" : "mic.fill",
                               tint: controller.inputMuted ? .red : .primary,
                               help: controller.inputMuted ? "Unmute microphone" : "Mute microphone") {
                        controller.setInputMuted(!controller.inputMuted)
                    }
                    .disabled(!controller.canMuteInput)
                } slider: {
                    SlimSlider(value: Binding(get: { controller.inputMuted ? 0 : volume }, set: { controller.setInputVolume($0) }),
                               label: "Input volume", valueText: percent)
                } value: {
                    controller.inputMuted ? "Muted" : percent(volume)
                }
                .padding(.bottom, 4)
            } else {
                HStack {
                    Text("This input has a fixed level.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if controller.canMuteInput {
                        Toggle("Mute", isOn: Binding(get: { controller.inputMuted }, set: { controller.setInputMuted($0) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, Metrics.inset)
            }

            PanelDivider()

            SectionLabel("Input")
            ForEach(controller.inputDevices) { info in
                let selected = info.id == controller.inputDevice?.id
                MenuRow {
                    controller.select(info.device, as: .input)
                } content: {
                    CircleIcon(symbol: info.device.kind == .builtIn ? "mic.fill" : info.device.kind.symbol, selected: selected, size: 24)
                    Text(info.device.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

// MARK: - Audio devices

struct DevicesPage: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(title: "Audio Devices", back: { controller.page = .main }) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Output")
                    ForEach(controller.outputDevices) { DeviceRow(info: $0, scope: .output) }
                    PanelDivider()
                    SectionLabel("Input")
                    ForEach(controller.inputDevices) { DeviceRow(info: $0, scope: .input) }
                }
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)

            Text("Click a device to make it the default. 48 kHz suits most music and video; changing a device's rate briefly interrupts its sound and affects every app using it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.inset)
                .padding(.top, 8)
        }
    }
}

private struct DeviceRow: View {
    let info: DeviceInfo
    let scope: AudioDevice.Scope
    @Environment(AudioController.self) private var controller

    var body: some View {
        let current = scope == .output ? controller.outputDevice : controller.inputDevice
        let selected = info.id == current?.id
        MenuRow {
            controller.select(info.device, as: scope)
        } content: {
            CircleIcon(symbol: info.device.kind.symbol, selected: selected, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.device.name).font(.system(size: 13)).lineLimit(1)
                Text(details).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            Spacer(minLength: 6)
            if info.canSetSampleRate {
                Menu {
                    ForEach(info.sampleRates, id: \.self) { rate in
                        Button {
                            controller.setSampleRate(rate, for: info.device)
                        } label: {
                            let title = Self.format(rate) + (rate == 48_000 ? " (Recommended)" : "")
                            if rate == info.sampleRate {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                    }
                } label: {
                    Text(Self.format(info.sampleRate)).font(.system(size: 11).monospacedDigit())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sample rate: how many times per second audio is measured. 48 kHz suits music and video; changing it briefly interrupts sound.")
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var details: String {
        var parts = ["\(info.channels) channel\(info.channels == 1 ? "" : "s")", info.device.kind.label]
        if !info.canSetSampleRate, info.sampleRate > 0 { parts.insert(Self.format(info.sampleRate), at: 1) }
        return parts.joined(separator: " · ")
    }

    static func format(_ rate: Double) -> String {
        "\((rate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
    }
}
