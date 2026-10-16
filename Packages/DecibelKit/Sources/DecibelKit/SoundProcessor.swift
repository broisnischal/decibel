import BSKernel
import Foundation

/// User-facing processing parameters. Persisted by the app and applied to every new processor.
public struct SoundSettings: Codable, Equatable, Sendable {
    public var boostDB: Float = 0
    public var eqEnabled = true
    public var eqGains = [Float](repeating: 0, count: Equalizer.bandCount)
    public var bassDB: Float = 0
    public var trebleDB: Float = 0
    public var balance: Float = 0
    public var width: Float = 1
    /// Software volume after the limiter, for outputs without a hardware volume control.
    public var outputGain: Float = 1

    public init() {}
}

public struct LevelMeters: Sendable {
    public var input: (left: Float, right: Float)
    public var output: (left: Float, right: Float)
    /// Deepest limiter gain reduction since the last read, in dB (>= 0).
    public var gainReduction: Float
    public var renderCount: UInt64
}

/// Owns a `BSKernel`. Every setter is lock-free and safe to call while audio is rendering.
public final class SoundProcessor: @unchecked Sendable {
    let kernel: OpaquePointer

    public init?(sampleRate: Double) {
        guard let kernel = BSKernelCreate(sampleRate) else { return nil }
        self.kernel = kernel
    }

    deinit { BSKernelDestroy(kernel) }

    public var sampleRate: Double { BSKernelGetSampleRate(kernel) }
    public var latencyFrames: Int { Int(BSKernelGetLatencyFrames(kernel)) }
    /// Seconds since any captured app last made sound (before per-app gain, so muted apps count).
    public var secondsSinceSound: Double { BSKernelSecondsSinceSound(kernel) }

    public func apply(_ settings: SoundSettings) {
        setBoost(settings.boostDB)
        setEQEnabled(settings.eqEnabled)
        for (band, gain) in settings.eqGains.prefix(Equalizer.bandCount).enumerated() {
            setEQGain(gain, band: band)
        }
        setBass(settings.bassDB)
        setTreble(settings.trebleDB)
        setBalance(settings.balance)
        setWidth(settings.width)
        setOutputGain(settings.outputGain)
    }

    public func setBoost(_ decibels: Float) { BSKernelSetBoost(kernel, decibels) }
    public func setEQEnabled(_ enabled: Bool) { BSKernelSetEQEnabled(kernel, enabled) }
    public func setEQGain(_ decibels: Float, band: Int) { BSKernelSetEQBandGain(kernel, Int32(band), decibels) }
    public func setBass(_ decibels: Float) { BSKernelSetEQBandGain(kernel, BS_EQ_BASS, decibels) }
    public func setTreble(_ decibels: Float) { BSKernelSetEQBandGain(kernel, BS_EQ_TREBLE, decibels) }
    public func setBalance(_ balance: Float) { BSKernelSetBalance(kernel, balance) }
    public func setWidth(_ width: Float) { BSKernelSetStereoWidth(kernel, width) }
    public func setLimiterCeiling(_ decibels: Float) { BSKernelSetLimiterCeiling(kernel, decibels) }
    public func setOutputGain(_ linear: Float) { BSKernelSetOutputGain(kernel, linear) }

    /// Source 0 is the shared tap; sources 1... are individually mixed apps.
    public func setSourceGain(_ linear: Float, source: Int) { BSKernelSetSourceGain(kernel, UInt32(source), linear) }
    public func readSourcePeak(source: Int) -> Float { BSKernelReadSourcePeak(kernel, UInt32(source)) }

    func setSources(streams: [UInt32]) {
        streams.withUnsafeBufferPointer { BSKernelSetSources(kernel, $0.baseAddress!, UInt32($0.count)) }
    }

    public func readMeters() -> LevelMeters {
        var m = BSMeters()
        BSKernelReadMeters(kernel, &m)
        return LevelMeters(input: (m.inputPeak.0, m.inputPeak.1),
                           output: (m.outputPeak.0, m.outputPeak.1),
                           gainReduction: m.gainReduction,
                           renderCount: m.renderCount)
    }

    /// Offline render (tests, previews). In-place.
    public func process(left: inout [Float], right: inout [Float]) {
        precondition(left.count == right.count)
        guard !left.isEmpty else { return }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                BSKernelProcess(kernel, l.baseAddress!, r.baseAddress!, l.baseAddress!, r.baseAddress!, UInt32(l.count))
            }
        }
    }
}
