import ForteKit
import SwiftUI

struct EqualizerPage: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(title: "Equalizer", back: { controller.page = .main }) {
                Toggle("Equalizer", isOn: $controller.eqEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            HStack {
                PresetMenu()
                Spacer()
                Button("Reset") { controller.resetEqualizer() }
                    .controlSize(.small)
                    .disabled(controller.isEqualizerFlat)
                    .help("Set every band, bass and treble back to 0 dB")
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.bottom, 10)

            Group {
                EQCurve(gains: controller.eqGains, bass: controller.bassDB, treble: controller.trebleDB,
                        sampleRate: controller.sampleRate)
                    .frame(height: 64)
                    .padding(.bottom, 10)

                HStack(spacing: 0) {
                    ForEach(0..<Equalizer.bandCount, id: \.self) { band in
                        VStack(spacing: 5) {
                            Text(gainLabel(controller.eqGains[band]))
                                .font(.system(size: 9, weight: .medium).monospacedDigit())
                                .foregroundStyle(controller.eqGains[band] == 0 ? .tertiary : .secondary)
                            BandFader(gain: $controller.eqGains[band], range: Equalizer.gainRange,
                                      active: controller.eqEnabled, label: Equalizer.label(forBand: band))
                                .frame(height: 120)
                            Text(Equalizer.label(forBand: band))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, Metrics.inset)

            PanelDivider()

            VStack(spacing: 10) {
                toneRow("Bass", value: $controller.bassDB)
                toneRow("Treble", value: $controller.trebleDB)
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, 2)
        }
        .opacity(controller.isEnabled ? 1 : 0.6)
    }

    private func toneRow(_ title: String, value: Binding<Float>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13)).frame(width: 48, alignment: .leading)
            Slider(value: value.snapping(to: 0, within: 0.75, step: 0.5), in: Equalizer.toneRange) { Text(title) }
                .labelsHidden()
                .controlSize(.small)
            Text(value.wrappedValue == 0 ? "0 dB" : String(format: "%+.1f dB", value.wrappedValue))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .contextMenu { Button("Reset to 0 dB") { value.wrappedValue = 0 } }
    }

    private func gainLabel(_ g: Float) -> String {
        g == 0 ? "0" : g == g.rounded() ? String(format: "%+.0f", g) : String(format: "%+.1f", g)
    }
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
            Button("Save Current as Preset…") {
                name = ""
                saving = true
            }
            if let current = controller.currentPreset, !current.isBuiltIn {
                Button("Delete “\(current.name)”", role: .destructive) { controller.delete(current) }
            }
        } label: {
            Text(controller.currentPreset?.name ?? "Custom")
        }
        .controlSize(.small)
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
    var sampleRate: Double
    @Environment(AudioController.self) private var controller

    private static let points = 120
    private static let range: Float = 15
    /// Columns are evenly spaced octaves starting at 32 Hz, so x = 0.05 is 32 Hz and each 0.1 is an octave.
    private static let frequencies: [Float] = (0..<points).map { i in
        32 * pow(2, (Float(i) / Float(points - 1) - 0.05) * 10)
    }

    var body: some View {
        let active = controller.eqEnabled
        let response = Equalizer.response(gains: gains, bass: bass, treble: treble, sampleRate: sampleRate, at: Self.frequencies)
        let range = Self.range, points = Self.points
        Canvas { ctx, size in
            let mid = size.height / 2
            func y(_ db: Float) -> CGFloat { mid - CGFloat(min(max(db, -range), range) / range) * (mid - 3) }

            for db: Float in [-12, -6, 6, 12] {
                ctx.stroke(Path { $0.move(to: .init(x: 0, y: y(db))); $0.addLine(to: .init(x: size.width, y: y(db))) },
                           with: .color(.primary.opacity(0.05)), lineWidth: 1)
            }
            ctx.stroke(Path { $0.move(to: .init(x: 0, y: mid)); $0.addLine(to: .init(x: size.width, y: mid)) },
                       with: .color(.primary.opacity(0.15)), lineWidth: 1)

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

            let color = active ? Color.accentColor : Color.secondary
            ctx.fill(area, with: .color(color.opacity(0.18)))
            ctx.stroke(curve, with: .color(color), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}
