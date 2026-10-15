import SwiftUI

enum Theme {
    static let accent = Color(red: 1.0, green: 0.56, blue: 0.16)
    static let boostGradient = LinearGradient(
        colors: [Color(red: 0.25, green: 0.78, blue: 0.55), accent, Color(red: 1.0, green: 0.27, blue: 0.23)],
        startPoint: .leading, endPoint: .trailing)
    static let meterGradient = LinearGradient(
        stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.6),
                .init(color: .yellow, location: 0.85), .init(color: .red, location: 1)],
        startPoint: .leading, endPoint: .trailing)
    static let track = Color.primary.opacity(0.12)
    static let card = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.07)
}

/// Compact pill tab bar.
struct TabBar: View {
    @Binding var selection: PanelTab
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(.spring(duration: 0.25)) { selection = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.primary.opacity(0.13))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.cardStroke))
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

/// Horizontal slider with a fill that grows from `origin`. Double-click resets to `resetValue`, which is also a detent.
struct FillSlider<Fill: ShapeStyle>: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var origin: Float?
    var resetValue: Float?
    var step: Float
    var fill: Fill
    /// Optional tick, e.g. 100 % on a slider that goes beyond it.
    var mark: Float? = nil
    var label: String
    var valueText: (Float) -> String

    @State private var dragging = false
    private let knob: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - knob, 1)
            let x = CGFloat(fraction(value)) * usable
            let x0 = CGFloat(fraction(origin ?? range.lowerBound)) * usable

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                    .frame(height: 4)
                    .padding(.horizontal, knob / 2)
                Capsule().fill(fill)
                    .frame(height: 4)
                    .padding(.horizontal, knob / 2)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: abs(x - x0)).offset(x: min(x, x0) + knob / 2)
                    }
                if let mark {
                    Capsule().fill(Color.primary.opacity(0.35))
                        .frame(width: 2, height: 10)
                        .offset(x: CGFloat(fraction(mark)) * usable + knob / 2 - 1)
                }
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .scaleEffect(dragging ? 1.12 : 1)
                    .animation(.spring(duration: 0.2), value: dragging)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        setFraction(Float((g.location.x - knob / 2) / usable))
                    }
                    .onEnded { _ in dragging = false }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { if let resetValue { value = resetValue } })
        }
        .frame(height: 22)
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step) { Text(label) }
                .accessibilityValue(valueText(value))
        }
    }

    private func fraction(_ v: Float) -> Float {
        (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func setFraction(_ f: Float) {
        let raw = range.lowerBound + min(max(f, 0), 1) * (range.upperBound - range.lowerBound)
        var snapped = (raw / step).rounded() * step
        if let resetValue, abs(snapped - resetValue) < step * 1.5 { snapped = resetValue } // Detent at the default.
        value = min(max(snapped, range.lowerBound), range.upperBound)
    }
}

/// Vertical fader for one EQ band, filled from 0 dB.
struct BandFader: View {
    @Binding var gain: Float
    let range: ClosedRange<Float>
    var active: Bool
    var label: String

    @State private var dragging = false
    private let capHeight: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.height - capHeight, 1)
            let y = CGFloat(1 - fraction(gain)) * usable
            let y0 = CGFloat(1 - fraction(0)) * usable

            ZStack(alignment: .top) {
                Capsule().fill(Theme.track)
                    .frame(width: 4)
                    .padding(.vertical, capHeight / 2)
                Rectangle().fill(Color.primary.opacity(0.18))
                    .frame(width: 10, height: 1)
                    .offset(y: y0 + capHeight / 2)
                Capsule().fill(active ? Theme.accent : Color.secondary)
                    .frame(width: 4, height: abs(y - y0))
                    .offset(y: min(y, y0) + capHeight / 2)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                    .overlay(Rectangle().fill(active ? Theme.accent : .secondary).frame(width: 10, height: 1.5))
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                    .frame(width: 20, height: capHeight)
                    .scaleEffect(dragging ? 1.1 : 1)
                    .animation(.spring(duration: 0.2), value: dragging)
                    .offset(y: y)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        let f = 1 - Float((g.location.y - capHeight / 2) / usable)
                        var v = range.lowerBound + min(max(f, 0), 1) * (range.upperBound - range.lowerBound)
                        v = (v * 2).rounded() / 2 // 0.5 dB steps
                        gain = abs(v) < 0.75 ? 0 : v
                    }
                    .onEnded { _ in dragging = false }
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

    private func position(_ db: Float) -> CGFloat { CGFloat(min(max((db + 60) / 60, 0), 1)) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Theme.meterGradient
                    .mask(alignment: .leading) { Rectangle().frame(width: w * position(level)) }
                    .clipShape(Capsule())
                Rectangle()
                    .fill(hold > -1.5 ? Color.red : Color.primary.opacity(0.6))
                    .frame(width: 2)
                    .offset(x: max(w * position(hold) - 2, 0))
                    .opacity(hold > -59 ? 1 : 0)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}
