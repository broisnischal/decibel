import BetterSoundKit
import SwiftUI

struct EqualizerTab: View {
    var body: some View {
        VStack(spacing: 10) {
            EqualizerCard()
            ToneCard()
        }
    }
}

private struct EqualizerCard: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        Card {
            SectionHeader(title: "EQUALIZER") {
                HStack(spacing: 8) {
                    PresetMenu()
                    Button {
                        controller.resetEqualizer()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(controller.isEqualizerFlat)
                    .help("Reset to flat")
                    .accessibilityLabel("Reset equalizer")
                    Toggle("Equalizer", isOn: $controller.eqEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .tint(Theme.accent)
                }
            }

            EQCurve(gains: controller.eqGains, bass: controller.bassDB, treble: controller.trebleDB,
                    active: controller.eqEnabled, sampleRate: controller.sampleRate)
                .frame(height: 54)

            HStack(spacing: 0) {
                ForEach(0..<Equalizer.bandCount, id: \.self) { band in
                    VStack(spacing: 5) {
                        Text(gainLabel(controller.eqGains[band]))
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(controller.eqGains[band] == 0 ? .tertiary : .secondary)
                        BandFader(gain: $controller.eqGains[band], range: Equalizer.gainRange,
                                  active: controller.eqEnabled, label: Equalizer.label(forBand: band))
                            .frame(height: 112)
                        Text(Equalizer.label(forBand: band))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func gainLabel(_ g: Float) -> String {
        g == 0 ? "0" : g == g.rounded() ? String(format: "%+.0f", g) : String(format: "%+.1f", g)
    }
}

private struct ToneCard: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        Card {
            SectionHeader(title: "TONE")
            LabeledSliderRow(title: "Bass", value: db(controller.bassDB)) {
                FillSlider(value: $controller.bassDB, range: Equalizer.toneRange, origin: 0, resetValue: 0, step: 0.5,
                           fill: Theme.accent, label: "Bass") { String(format: "%+.1f decibels", $0) }
            }
            LabeledSliderRow(title: "Treble", value: db(controller.trebleDB)) {
                FillSlider(value: $controller.trebleDB, range: Equalizer.toneRange, origin: 0, resetValue: 0, step: 0.5,
                           fill: Theme.accent, label: "Treble") { String(format: "%+.1f decibels", $0) }
            }
        }
        .opacity(controller.eqEnabled ? 1 : 0.55)
    }

    private func db(_ v: Float) -> String { v == 0 ? "0 dB" : String(format: "%+.1f dB", v) }
}

private struct PresetMenu: View {
    @Environment(AudioController.self) private var controller
    @State private var saving = false
    @State private var name = ""

    var body: some View {
        Menu {
            Section("Presets") {
                ForEach(EQPreset.builtIns) { item($0) }
            }
            if !controller.customPresets.isEmpty {
                Section("My Presets") {
                    ForEach(controller.customPresets) { item($0) }
                }
            }
            Divider()
            Button("Save Current Curve…") {
                name = ""
                saving = true
            }
            if let current = controller.currentPreset, !current.isBuiltIn {
                Button("Delete “\(current.name)”", role: .destructive) { controller.delete(current) }
            }
        } label: {
            Text(controller.currentPreset?.name ?? "Custom")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .popover(isPresented: $saving, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Save Preset").font(.headline)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(save)
                HStack {
                    Spacer()
                    Button("Cancel") { saving = false }
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
        }
    }

    private func item(_ preset: EQPreset) -> some View {
        Button {
            controller.apply(preset)
        } label: {
            if preset.id == controller.currentPreset?.id {
                Label(preset.name, systemImage: "checkmark")
            } else {
                Text(preset.name)
            }
        }
    }

    private func save() {
        controller.saveCurrentAsPreset(named: name)
        saving = false
    }
}

/// Live EQ response. The x axis is log-frequency aligned so each band's centre sits above its fader.
struct EQCurve: View {
    var gains: [Float]
    var bass: Float
    var treble: Float
    var active: Bool
    var sampleRate: Double

    private static let points = 120
    private static let range: Float = 15
    /// Columns are evenly spaced octaves starting at 32 Hz, so x = 0.05 is 32 Hz and each 0.1 is an octave.
    private static let frequencies: [Float] = (0..<points).map { i in
        32 * pow(2, (Float(i) / Float(points - 1) - 0.05) * 10)
    }

    var body: some View {
        let response = Equalizer.response(gains: gains, bass: bass, treble: treble, sampleRate: sampleRate, at: Self.frequencies)
        let range = Self.range, points = Self.points
        Canvas { ctx, size in
            let mid = size.height / 2
            func y(_ db: Float) -> CGFloat { mid - CGFloat(min(max(db, -range), range) / range) * (mid - 2) }

            for db: Float in [-12, -6, 6, 12] {
                ctx.stroke(Path { $0.move(to: .init(x: 0, y: y(db))); $0.addLine(to: .init(x: size.width, y: y(db))) },
                           with: .color(.primary.opacity(0.05)), lineWidth: 1)
            }
            ctx.stroke(Path { $0.move(to: .init(x: 0, y: mid)); $0.addLine(to: .init(x: size.width, y: mid)) },
                       with: .color(.primary.opacity(0.14)), lineWidth: 1)

            let step = size.width / CGFloat(points - 1)
            var curve = Path()
            for (i, db) in response.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: y(active ? db : 0))
                i == 0 ? curve.move(to: p) : curve.addLine(to: p)
            }
            var area = curve
            area.addLine(to: .init(x: size.width, y: mid))
            area.addLine(to: .init(x: 0, y: mid))
            area.closeSubpath()

            let color = active ? Theme.accent : Color.secondary
            ctx.fill(area, with: .color(color.opacity(0.16)))
            ctx.stroke(curve, with: .color(color), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}
