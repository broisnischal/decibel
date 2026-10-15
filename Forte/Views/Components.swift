import AppKit
import ForteKit
import SwiftUI

// Building blocks modelled on the macOS Sound menu and Control Center.

enum Metrics {
    static let panelWidth: CGFloat = 320
    static let inset: CGFloat = 14
}

/// Slim modern slider: a thin track (it thickens on hover) with a tinted fill and a pill knob.
struct SlimSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float> = 0...1
    var step: Float = 0.005
    /// Snap point with a tick mark, e.g. 100 % on a slider that goes beyond it.
    var detent: Float?
    var tint: Color = .accentColor
    var label: String
    var valueText: (Float) -> String

    @State private var hovering = false
    @State private var dragging = false
    @Environment(\.isEnabled) private var isEnabled

    private let knob = CGSize(width: 20, height: 12)

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - knob.width, 1)
            let x = travel * CGFloat(fraction(value))
            let thickness: CGFloat = hovering || dragging ? 6 : 4

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                    .frame(height: thickness)
                Capsule().fill(isEnabled ? tint : Color.secondary)
                    .frame(width: x + knob.width / 2, height: thickness)
                if let detent {
                    Capsule().fill(Color.primary.opacity(0.35))
                        .frame(width: 2, height: 8)
                        .offset(x: knob.width / 2 + travel * CGFloat(fraction(detent)) - 1)
                }
                Capsule()
                    .fill(.white)
                    .overlay(Capsule().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: knob.width, height: knob.height)
                    .scaleEffect(dragging ? 1.15 : 1)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        set(Float((g.location.x - knob.width / 2) / travel))
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(.easeOut(duration: 0.15), value: thickness)
            .animation(.spring(duration: 0.2), value: dragging)
        }
        .frame(height: 18)
        .onHover { hovering = $0 }
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step) { Text(label) }
                .accessibilityValue(valueText(value))
        }
    }

    private func fraction(_ v: Float) -> Float {
        min(max((v - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    private func set(_ f: Float) {
        var v = range.lowerBound + min(max(f, 0), 1) * (range.upperBound - range.lowerBound)
        v = (v / step).rounded() * step
        if let detent, abs(v - detent) < (range.upperBound - range.lowerBound) * 0.025 { v = detent }
        value = min(max(v, range.lowerBound), range.upperBound)
    }
}

/// A small borderless symbol button (mute toggles and the like) with a hover highlight.
struct IconButton: View {
    let symbol: String
    var tint: Color = .primary
    var size: CGFloat = 13
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovering ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Leading control, slim slider and trailing value on one line.
struct SliderRow<Leading: View>: View {
    let leading: Leading
    let slider: SlimSlider
    let value: String

    init(@ViewBuilder leading: () -> Leading, slider: () -> SlimSlider, value: () -> String) {
        self.leading = leading()
        self.slider = slider()
        self.value = value()
    }

    var body: some View {
        HStack(spacing: 8) {
            leading
            slider
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.leading, Metrics.inset - 4)
        .padding(.trailing, Metrics.inset)
    }
}

/// Vertical EQ fader with a native-looking round knob, filled from 0 dB in the accent colour.
struct BandFader: View {
    @Binding var gain: Float
    let range: ClosedRange<Float>
    var active: Bool
    var label: String

    private let knob: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.height - knob, 1)
            let y = CGFloat(1 - fraction(gain)) * usable
            let y0 = CGFloat(1 - fraction(0)) * usable

            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.12))
                    .frame(width: 4)
                    .padding(.vertical, knob / 2)
                Capsule().fill(Color.primary.opacity(0.25))
                    .frame(width: 8, height: 1)
                    .offset(y: y0 + knob / 2)
                Capsule().fill(active ? Color.accentColor : Color.secondary)
                    .frame(width: 4, height: abs(y - y0))
                    .offset(y: min(y, y0) + knob / 2)
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(y: y)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let f = 1 - Float((g.location.y - knob / 2) / usable)
                    var v = range.lowerBound + min(max(f, 0), 1) * (range.upperBound - range.lowerBound)
                    v = (v * 2).rounded() / 2 // 0.5 dB steps
                    gain = abs(v) < 0.75 ? 0 : v
                }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { gain = 0 })
        }
        .accessibilityRepresentation {
            Slider(value: $gain, in: range, step: 0.5) { Text("\(label) hertz") }
                .accessibilityValue(String(format: "%+.1f decibels", gain))
        }
    }

    private func fraction(_ v: Float) -> Float {
        (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}

/// Horizontal peak meter, -60...0 dBFS, with a peak-hold tick.
struct PeakMeter: View {
    var level: Float
    var hold: Float

    private static let gradient = LinearGradient(
        stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.6),
                .init(color: .yellow, location: 0.85), .init(color: .red, location: 1)],
        startPoint: .leading, endPoint: .trailing)

    private func position(_ db: Float) -> CGFloat { CGFloat(min(max((db + 60) / 60, 0), 1)) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Self.gradient
                    .mask(alignment: .leading) { Rectangle().frame(width: w * position(level)) }
                    .clipShape(Capsule())
                Rectangle()
                    .fill(hold > -1.5 ? Color.red : Color.primary.opacity(0.6))
                    .frame(width: 2)
                    .offset(x: max(w * position(hold) - 2, 0))
                    .opacity(hold > -59 ? 1 : 0)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// A menu-style row: full width, rounded hover highlight, like the rows in the macOS Sound menu.
struct MenuRow<Content: View>: View {
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { content }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.09) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, Metrics.inset - 8)
    }
}

/// Round glyph used for devices and pages; filled with the accent colour when selected.
struct CircleIcon: View {
    let symbol: String
    var selected = false
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(width: size, height: size)
            .background(Circle().fill(selected ? Color.accentColor : Color.primary.opacity(0.1)))
    }
}

struct SectionLabel<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }
}

extension SectionLabel where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

struct PanelDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, 6)
    }
}

/// Title row with an optional trailing control (e.g. a switch), like a Control Center module header.
struct PanelTitle<Trailing: View>: View {
    let title: String
    var back: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Back")
            }
            Text(title).font(.system(size: 13, weight: .bold))
            Spacer()
            trailing
        }
        .frame(minHeight: 24)
        .padding(.horizontal, Metrics.inset)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

struct AppIcon: View {
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

enum VolumeSymbol {
    static func name(volume: Float, muted: Bool) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        return volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

func percent(_ value: Float) -> String { "\(Int((value * 100).rounded()))%" }

extension Binding where Value == Float {
    /// Rounds to `step` and snaps to `target` when close, so continuous (tick-free) native sliders still land on
    /// clean values and their default.
    func snapping(to target: Float, within tolerance: Float, step: Float) -> Binding<Float> {
        Binding(get: { wrappedValue }, set: { newValue in
            var v = (newValue / step).rounded() * step
            if abs(v - target) < tolerance { v = target }
            wrappedValue = v
        })
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
        case .other: "hifispeaker.fill"
        }
    }

    var label: String {
        switch self {
        case .builtIn: "Built-in"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .airPlay: "AirPlay"
        case .display: "Display"
        case .virtual: "Virtual"
        case .other: "External"
        }
    }
}
