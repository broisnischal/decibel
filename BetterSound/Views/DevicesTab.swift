import BetterSoundKit
import SwiftUI

struct DevicesTab: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        VStack(spacing: 10) {
            DeviceList(title: "OUTPUT", scope: .output, devices: controller.outputDevices, current: controller.outputDevice)
            DeviceList(title: "INPUT", scope: .input, devices: controller.inputDevices, current: controller.inputDevice)
        }
    }
}

private struct DeviceList: View {
    let title: String
    let scope: AudioDevice.Scope
    let devices: [DeviceInfo]
    let current: AudioDevice?

    var body: some View {
        Card {
            SectionHeader(title: title) {
                Text("\(devices.count) device\(devices.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if devices.isEmpty {
                Text("No devices").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(devices) { info in
                    DeviceRow(info: info, scope: scope, isDefault: info.id == current?.id)
                }
            }
        }
    }
}

private struct DeviceRow: View {
    let info: DeviceInfo
    let scope: AudioDevice.Scope
    let isDefault: Bool
    @Environment(AudioController.self) private var controller
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: info.device.kind.symbol)
                .font(.system(size: 13))
                .foregroundStyle(isDefault ? Theme.accent : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(info.device.name)
                    .font(.system(size: 12, weight: isDefault ? .semibold : .regular))
                    .lineLimit(1)
                Text(details)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if info.canSetSampleRate {
                Menu {
                    ForEach(info.sampleRates, id: \.self) { rate in
                        Button {
                            controller.setSampleRate(rate, for: info.device)
                        } label: {
                            if rate == info.sampleRate {
                                Label(Self.format(rate), systemImage: "checkmark")
                            } else {
                                Text(Self.format(rate))
                            }
                        }
                    }
                } label: {
                    Text(Self.format(info.sampleRate)).font(.system(size: 10).monospacedDigit())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sample rate")
            }

            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)
                .opacity(isDefault ? 1 : 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering && !isDefault ? Theme.card : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !isDefault { controller.select(info.device, as: scope) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isDefault ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { controller.select(info.device, as: scope) }
        .help(isDefault ? "Current \(scope == .output ? "output" : "input")" : "Use this device")
    }

    private var details: String {
        var parts = ["\(info.channels) ch"]
        if !info.canSetSampleRate, info.sampleRate > 0 { parts.append(Self.format(info.sampleRate)) }
        parts.append(info.device.kind.label)
        return parts.joined(separator: " · ")
    }

    static func format(_ rate: Double) -> String {
        "\((rate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
    }
}

extension AudioDevice.Kind {
    var label: String {
        switch self {
        case .builtIn: "Built-in"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .airPlay: "AirPlay"
        case .display: "Display"
        case .virtual: "Virtual"
        case .other: "Other"
        }
    }
}
