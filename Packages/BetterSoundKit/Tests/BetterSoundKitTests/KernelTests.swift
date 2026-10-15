import BSKernel
import CoreAudio
import Foundation
import Testing
@testable import BetterSoundKit

private let sampleRate = 48_000.0

private func sine(_ frequency: Double, amplitude: Float, frames: Int, phase: Double = 0) -> [Float] {
    (0..<frames).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate + phase)) }
}

private func rms(_ x: ArraySlice<Float>) -> Float {
    (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

private func dB(_ x: Float) -> Float { 20 * log10(x) }

@Suite struct ProcessorTests {
    @Test func defaultSettingsAreTransparent() throws {
        let p = try #require(SoundProcessor(sampleRate: sampleRate))
        let input = sine(440, amplitude: 0.5, frames: 4800)
        var l = input, r = input.map { -$0 }
        p.process(left: &l, right: &r)

        let latency = p.latencyFrames
        for i in latency..<input.count {
            #expect(abs(l[i] - input[i - latency]) < 1e-5)
            #expect(abs(r[i] + input[i - latency]) < 1e-5)
        }
        #expect(p.readMeters().gainReduction == 0)
    }

    @Test(arguments: [0, 6, 12, 18, 24] as [Float])
    func limiterHoldsTheCeiling(boost: Float) throws {
        let p = try #require(SoundProcessor(sampleRate: sampleRate))
        p.setBoost(boost)
        p.setEQGain(12, band: 0)
        p.setEQGain(12, band: 1)

        // Full-scale tone, a burst and white noise: the worst cases for overs.
        var l = sine(60, amplitude: 1, frames: 24_000) + [Float](repeating: 0, count: 2000) + (0..<24_000).map { _ in Float.random(in: -1...1) }
        var r = l.reversed() as [Float]
        p.process(left: &l, right: &r)

        let ceiling = pow(10, Float(-1) / 20)
        #expect(l.allSatisfy { abs($0) <= ceiling + 1e-6 })
        #expect(r.allSatisfy { abs($0) <= ceiling + 1e-6 })
        if boost > 0 { #expect(p.readMeters().gainReduction > 0) }
    }

    @Test func boostIsAccurateBelowTheCeiling() throws {
        let p = try #require(SoundProcessor(sampleRate: sampleRate))
        p.setBoost(6)
        var l = sine(1000, amplitude: 0.1, frames: 9600), r = l
        p.process(left: &l, right: &r)
        #expect(abs(dB(rms(l[4800...]) / rms(sine(1000, amplitude: 0.1, frames: 9600)[4800...])) - 6) < 0.05)
    }

    @Test(arguments: 1..<(Equalizer.bandCount - 1))
    func peakingBandHitsItsGainAtCentre(band: Int) throws {
        let p = try #require(SoundProcessor(sampleRate: sampleRate))
        p.setEQGain(6, band: band)
        let f = Double(Equalizer.frequencies[band])
        let input = sine(f, amplitude: 0.1, frames: 48_000)
        var l = input, r = input
        p.process(left: &l, right: &r)
        let measured = dB(rms(l[24_000...]) / rms(input[24_000...]))
        #expect(abs(measured - 6) < 0.25, "band \(band) @ \(f) Hz measured \(measured) dB")

        let predicted = Equalizer.response(gains: (0..<10).map { $0 == band ? 6 : 0 }, sampleRate: sampleRate, at: [Float(f)])[0]
        #expect(abs(predicted - 6) < 0.01)
    }

    @Test func toneControlsShapeTheExtremes() throws {
        let p = try #require(SoundProcessor(sampleRate: sampleRate))
        p.setBass(9)
        p.setTreble(-9)
        func gain(at f: Double) -> Float {
            let input = sine(f, amplitude: 0.05, frames: 48_000)
            var l = input, r = input
            p.process(left: &l, right: &r)
            return dB(rms(l[24_000...]) / rms(input[24_000...]))
        }
        #expect(abs(gain(at: 30) - 9) < 0.5)
        #expect(abs(gain(at: 1000)) < 1)
        #expect(abs(gain(at: 18_000) + 9) < 1)

        let predicted = Equalizer.response(gains: [], bass: 9, treble: -9, sampleRate: sampleRate, at: [30, 18_000])
        #expect(abs(predicted[0] - 9) < 0.5 && abs(predicted[1] + 9) < 1)
    }

    @Test func outputGainScalesAfterTheLimiter() throws {
        let p = try #require(SoundProcessor(sampleRate: sampleRate))
        p.setBoost(12)
        p.setOutputGain(0.25)
        var l = sine(200, amplitude: 1, frames: 48_000), r = l
        p.process(left: &l, right: &r)
        let ceiling = pow(10, Float(-1) / 20)
        #expect(abs(l[24_000...].map(abs).max()! - ceiling * 0.25) < 0.01)
    }

    @Test func disablingEQBypassesIt() throws {
        let p = try #require(SoundProcessor(sampleRate: sampleRate))
        for b in 0..<Equalizer.bandCount { p.setEQGain(9, band: b) }
        p.setBass(9)
        p.setTreble(9)
        p.setEQEnabled(false)
        let input = sine(250, amplitude: 0.2, frames: 9600)
        var l = input, r = input
        p.process(left: &l, right: &r)
        #expect(abs(dB(rms(l[4800...]) / rms(input[4800...]))) < 0.05)
    }

    @Test func widthZeroIsMonoAndBalanceMutesASide() throws {
        let p = try #require(SoundProcessor(sampleRate: sampleRate))
        p.setWidth(0)
        p.setBalance(-1)
        // Parameters glide over ~20 ms, so measure the second half of a one-second render.
        var l = sine(300, amplitude: 0.3, frames: 48_000), r = sine(500, amplitude: 0.2, frames: 48_000)
        p.process(left: &l, right: &r)
        #expect(rms(l[24_000...]) > 0.05)
        #expect(rms(r[24_000...]) < 1e-5)

        p.setBalance(0)
        l = sine(300, amplitude: 0.3, frames: 48_000)
        r = sine(500, amplitude: 0.2, frames: 48_000)
        p.process(left: &l, right: &r)
        #expect(zip(l[24_000...], r[24_000...]).allSatisfy { abs($0 - $1) < 1e-5 })
    }

    @Test func recoversFromNonFiniteInput() throws {
        let p = try #require(SoundProcessor(sampleRate: sampleRate))
        p.setEQGain(6, band: 3)
        var l = [Float](repeating: .nan, count: 64) + sine(1000, amplitude: 0.1, frames: 4800)
        var r = [Float](repeating: .infinity, count: 64) + sine(1000, amplitude: 0.1, frames: 4800)
        p.process(left: &l, right: &r)
        #expect(l.allSatisfy(\.isFinite) && r.allSatisfy(\.isFinite))
        #expect(rms(l[2400...]) > 0.05)
    }
}

@Suite struct IOProcTests {
    private var time = AudioTimeStamp()

    private func render(_ p: SoundProcessor, _ input: UnsafeMutableAudioBufferListPointer, _ output: UnsafeMutableAudioBufferListPointer) -> OSStatus {
        var t = time
        return BSKernelIOProc(0, &t, input.unsafePointer, &t, output.unsafeMutablePointer, &t, UnsafeMutableRawPointer(p.kernel))
    }

    /// Builds a buffer list where each entry is (channels, sample generator by frame/channel).
    private func makeList(_ buffers: [(channels: Int, value: (Int, Int) -> Float)], frames: Int) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: max(buffers.count, 1))
        list.count = buffers.count
        for (i, b) in buffers.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * b.channels)
            for f in 0..<frames { for c in 0..<b.channels { data[f * b.channels + c] = b.value(f, c) } }
            list[i] = AudioBuffer(mNumberChannels: UInt32(b.channels), mDataByteSize: UInt32(frames * b.channels * 4), mData: data)
        }
        return list
    }

    private func samples(_ list: UnsafeMutableAudioBufferListPointer, buffer: Int, channel: Int, frames: Int) -> [Float] {
        let b = list[buffer]
        let p = b.mData!.assumingMemoryBound(to: Float.self)
        return (0..<frames).map { p[$0 * Int(b.mNumberChannels) + channel] }
    }

    private func free(_ list: UnsafeMutableAudioBufferListPointer) {
        for b in list { b.mData?.deallocate() }
        list.unsafeMutablePointer.deallocate()
    }

    @Test func readsTapAfterDeviceInputsAndWritesFirstTwoOutputChannels() throws {
        let p = try #require(SoundProcessor(sampleRate: sampleRate))
        p.setSources(streams: [1])
        let frames = 1024, latency = p.latencyFrames

        // Buffer 0: a microphone (must be ignored). Buffer 1: interleaved stereo tap.
        let input = makeList([(1, { _, _ in 0.9 }), (2, { _, c in c == 0 ? 0.25 : -0.5 })], frames: frames)
        // Six-channel output split across a stereo and a 4-channel buffer.
        let output = makeList([(2, { _, _ in 0.7 }), (4, { _, _ in 0.7 })], frames: frames)
        defer { free(input); free(output) }

        let status = render(p, input, output)
        #expect(status == noErr)

        let left = samples(output, buffer: 0, channel: 0, frames: frames)
        let right = samples(output, buffer: 0, channel: 1, frames: frames)
        #expect(left[latency...].allSatisfy { abs($0 - 0.25) < 1e-4 })
        #expect(right[latency...].allSatisfy { abs($0 + 0.5) < 1e-4 })
        for c in 0..<4 { #expect(samples(output, buffer: 1, channel: c, frames: frames).allSatisfy { $0 == 0 }) }
    }

    @Test func mixesSourcesAtTheirOwnGainIntoMonoOutput() throws {
        let p = try #require(SoundProcessor(sampleRate: sampleRate))
        let frames = 4096, latency = p.latencyFrames // Larger than the kernel's internal chunk.
        // Global tap (stereo), an app at 50 %, and a muted app.
        let input = makeList([(2, { _, c in c == 0 ? 0.2 : 0.1 }), (1, { _, _ in 0.4 }), (2, { _, _ in 0.9 })], frames: frames)
        let output = makeList([(1, { _, _ in 1 })], frames: frames)
        defer { free(input); free(output) }

        p.setSourceGain(0.5, source: 1)
        p.setSourceGain(0, source: 2)
        p.setSources(streams: [0, 1, 2])
        _ = render(p, input, output)
        // Mono fold of L = 0.2 + 0.2, R = 0.1 + 0.2.
        #expect(samples(output, buffer: 0, channel: 0, frames: frames)[latency...].allSatisfy { abs($0 - 0.35) < 1e-4 })
        #expect(abs(p.readSourcePeak(source: 1) - 0.4) < 1e-6)
        #expect(abs(p.readSourcePeak(source: 2) - 0.9) < 1e-6) // Muted apps still report activity.
        #expect(p.readSourcePeak(source: 2) == 0) // Reading resets.
    }

    @Test func sourceGainChangesGlideWithoutClicks() throws {
        let p = try #require(SoundProcessor(sampleRate: sampleRate))
        let frames = 512
        let input = makeList([(2, { _, _ in 0.5 })], frames: frames)
        let output = makeList([(2, { _, _ in 0 })], frames: frames)
        defer { free(input); free(output) }
        for _ in 0..<10 { _ = render(p, input, output) }

        p.setSourceGain(0, source: 0)
        _ = render(p, input, output)
        let ramp = samples(output, buffer: 0, channel: 0, frames: frames)
        let steps = zip(ramp, ramp.dropFirst()).map { abs($0 - $1) }
        #expect(steps.max()! < 0.01)
        #expect(ramp.last! < ramp.first!)
    }

    @Test func missingInputRendersSilence() throws {
        let p = try #require(SoundProcessor(sampleRate: sampleRate))
        let input = makeList([], frames: 512)
        let output = makeList([(2, { _, _ in 1 })], frames: 512)
        defer { free(input); free(output) }
        _ = render(p, input, output)
        #expect(samples(output, buffer: 0, channel: 0, frames: 512).allSatisfy { $0 == 0 })
        #expect(p.readMeters().renderCount == 1)
    }
}

@Suite struct EqualizerTests {
    @Test func presetsCoverEveryBandWithinRange() {
        for preset in EQPreset.builtIns {
            #expect(preset.gains.count == Equalizer.bandCount, "\(preset.name)")
            #expect(preset.gains.allSatisfy { Equalizer.gainRange.contains($0) }, "\(preset.name)")
        }
        #expect(Set(EQPreset.builtIns.map(\.id)).count == EQPreset.builtIns.count)
    }

    @Test func flatResponseIsZero() {
        let r = Equalizer.response(gains: EQPreset.flat.gains, at: Equalizer.logFrequencies(count: 64))
        #expect(r.allSatisfy { $0 == 0 })
    }
}
