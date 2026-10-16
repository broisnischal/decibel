import DecibelKit
import Foundation
import Observation

/// Meter readings with display ballistics. Polls the kernel only while the panel is visible.
@MainActor @Observable
final class MeterModel {
    private(set) var output: [Float] = [-120, -120]       // dBFS, with fall-off
    private(set) var peakHold: [Float] = [-120, -120]
    private(set) var gainReduction: Float = 0              // dB, with release
    /// Pre-gain level (dBFS, with fall-off) of each app that has its own tap.
    private(set) var appLevels: [String: Float] = [:]

    var isVisible = false { didSet { updateTimer() } }

    @ObservationIgnored var router: SystemAudioRouter? {
        didSet {
            if router == nil { reset() }
            updateTimer()
        }
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var holdUntil: [Date] = [.distantPast, .distantPast]
    @ObservationIgnored private var lastTick = Date()

    private func updateTimer() {
        let shouldRun = isVisible && router != nil
        guard shouldRun != (timer != nil) else { return }
        if shouldRun {
            _ = router?.processor.readMeters() // Drop peaks accumulated while hidden.
            lastTick = Date()
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common) // Keep updating while a slider is being dragged.
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func reset() {
        output = [-120, -120]
        peakHold = [-120, -120]
        gainReduction = 0
        appLevels = [:]
    }

    private static func dB(_ x: Float) -> Float { 20 * log10(max(x, 1e-6)) }

    private func tick() {
        guard let router else { return }
        let reading = router.processor.readMeters()
        let now = Date()
        let dt = Float(now.timeIntervalSince(lastTick))
        lastTick = now

        // Assign only on change: every observed write re-renders the views reading it.
        let peaks = [reading.output.left, reading.output.right].map(Self.dB)
        var newOutput = output, newHold = peakHold
        for c in 0..<2 {
            newOutput[c] = max(-120, max(peaks[c], output[c] - 30 * dt)) // 30 dB/s fall
            if peaks[c] >= peakHold[c] {
                newHold[c] = peaks[c]
                holdUntil[c] = now.addingTimeInterval(1.2)
            } else if now > holdUntil[c] {
                newHold[c] = max(newOutput[c], peakHold[c] - 20 * dt)
            }
        }
        if newOutput != output { output = newOutput }
        if newHold != peakHold { peakHold = newHold }
        let reduction = max(0, max(reading.gainReduction, gainReduction - 12 * dt))
        if reduction != gainReduction { gainReduction = reduction }

        var levels: [String: Float] = [:]
        for tap in router.plan.appTaps {
            let peak = Self.dB(router.readPeak(forApp: tap.appID) ?? 0)
            levels[tap.appID] = max(-120, max(peak, (appLevels[tap.appID] ?? -120) - 30 * dt))
        }
        if levels != appLevels { appLevels = levels }
    }
}
