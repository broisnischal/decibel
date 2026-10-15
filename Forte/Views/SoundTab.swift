import ForteKit
import SwiftUI

struct SoundTab: View {
    var body: some View {
        VStack(spacing: 10) {
            BoostCard()
            StereoCard()
            MicrophoneCard()
        }
    }
}

// MARK: - Boost

private struct BoostCard: View {
    @Environment(AudioController.self) private var controller
    @Environment(MeterModel.self) private var meters

    var body: some View {
        @Bindable var controller = controller
        Card {
            SectionHeader(title: "VOLUME BOOST") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%+.1f dB", controller.boostDB))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(percent(controller.boostDB))
                        .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                }
            }

            FillSlider(value: $controller.boostDB, range: 0...AudioController.maxBoostDB, origin: nil,
                       resetValue: 0, step: 0.25, fill: Theme.boostGradient, label: "Volume boost",
                       valueText: percent)

            HStack {
                ForEach(["100%", "200%", "400%", "800%"], id: \.self) { mark in
                    Text(mark)
                    if mark != "800%" { Spacer() }
                }
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 2)

            HStack(spacing: 10) {
                VStack(spacing: 4) {
                    meterRow("L", 0)
                    meterRow("R", 1)
                }
                LimiterBadge(reduction: meters.gainReduction)
            }
            .padding(.top, 2)
        }
    }

    private func meterRow(_ label: String, _ channel: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 8)
            PeakMeter(level: meters.output[channel], hold: meters.peakHold[channel])
        }
    }

    private func percent(_ db: Float) -> String {
        "\(Int((pow(10, db / 20) * 100).rounded()))%"
    }
}

private struct LimiterBadge: View {
    var reduction: Float

    var body: some View {
        let active = reduction > 0.1
        HStack(spacing: 4) {
            Circle()
                .fill(active ? Theme.accent : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(active ? String(format: "Limit −%.1f", reduction) : "Limiter")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(active ? .primary : .secondary)
        }
        .frame(width: 78, alignment: .trailing)
        .help("The limiter keeps boosted audio from clipping.")
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stereo

private struct StereoCard: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        Card {
            SectionHeader(title: "STEREO")
            LabeledSliderRow(title: "Balance", value: balanceText(controller.balance)) {
                FillSlider(value: $controller.balance, range: -1...1, origin: 0, resetValue: 0, step: 0.05,
                           fill: Theme.accent, label: "Balance", valueText: balanceText)
            }
            LabeledSliderRow(title: "Width", value: "\(Int((controller.width * 100).rounded()))%") {
                FillSlider(value: $controller.width, range: 0...2, origin: 1, resetValue: 1, step: 0.05,
                           fill: Theme.accent, label: "Stereo width") { "\(Int(($0 * 100).rounded())) percent" }
            }
        }
    }

    private func balanceText(_ b: Float) -> String {
        let pct = Int((abs(b) * 100).rounded())
        return pct == 0 ? "Center" : (b < 0 ? "L \(pct)" : "R \(pct)")
    }
}

// MARK: - Microphone

private struct MicrophoneCard: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        Card {
            SectionHeader(title: "MICROPHONE") {
                Menu {
                    ForEach(controller.inputDevices) { info in
                        Button {
                            controller.select(info.device, as: .input)
                        } label: {
                            if info.id == controller.inputDevice?.id {
                                Label(info.device.name, systemImage: "checkmark")
                            } else {
                                Text(info.device.name)
                            }
                        }
                    }
                } label: {
                    Text(controller.inputDevice?.name ?? "No input")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Input device")
            }

            HStack(spacing: 8) {
                Button {
                    controller.setInputMuted(!controller.inputMuted)
                } label: {
                    Image(systemName: controller.inputMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(controller.inputMuted ? Color.red : .primary)
                .disabled(!controller.canMuteInput)
                .help(controller.inputMuted ? "Unmute microphone" : "Mute microphone")
                .accessibilityLabel(controller.inputMuted ? "Unmute microphone" : "Mute microphone")

                if let volume = controller.inputVolume {
                    FillSlider(value: Binding(get: { volume }, set: { controller.setInputVolume($0) }),
                               range: 0...1, origin: nil, resetValue: nil, step: 1.0 / 64,
                               fill: Theme.accent, label: "Input volume") { "\(Int(($0 * 100).rounded())) percent" }
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                } else {
                    Text("This input has a fixed level.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .opacity(controller.inputMuted ? 0.6 : 1)
        }
    }
}

struct LabeledSliderRow<S: View>: View {
    let title: String
    let value: String
    @ViewBuilder var slider: S

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 54, alignment: .leading)
            slider
            Text(value)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
