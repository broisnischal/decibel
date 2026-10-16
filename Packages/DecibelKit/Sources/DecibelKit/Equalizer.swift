import BSKernel
import Foundation

public enum Equalizer {
    public static let bandCount = Int(BS_EQ_BAND_COUNT)
    public static let gainRange: ClosedRange<Float> = -12...12
    public static let toneRange: ClosedRange<Float> = -12...12

    public static let frequencies: [Float] = withUnsafeBytes(of: BSEQBandFrequencies) {
        Array($0.bindMemory(to: Float.self).prefix(bandCount))
    }

    public static func label(forBand band: Int) -> String {
        let f = frequencies[band]
        return f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
    }

    /// Summed magnitude response (dB) of the graphic bands plus the bass/treble shelves at each frequency.
    public static func response(gains: [Float], bass: Float = 0, treble: Float = 0, sampleRate: Double = 48_000,
                                at frequencies: [Float]) -> [Float] {
        guard !frequencies.isEmpty else { return [] }
        var filters = Array(gains.prefix(bandCount))
        filters += [Float](repeating: 0, count: bandCount - filters.count)
        filters += [bass, treble]
        var out = [Float](repeating: 0, count: frequencies.count)
        filters.withUnsafeBufferPointer { g in
            frequencies.withUnsafeBufferPointer { f in
                out.withUnsafeMutableBufferPointer { o in
                    BSEQComputeResponse(g.baseAddress!, sampleRate, f.baseAddress!, o.baseAddress!, UInt32(f.count))
                }
            }
        }
        return out
    }

    /// `count` log-spaced frequencies across the audible range.
    public static func logFrequencies(count: Int, from low: Float = 20, to high: Float = 20_000) -> [Float] {
        let ratio = log(high / low)
        return (0..<count).map { low * exp(ratio * Float($0) / Float(max(count - 1, 1))) }
    }
}

public struct EQPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var gains: [Float]
    public var isBuiltIn: Bool

    public init(id: String = UUID().uuidString, name: String, gains: [Float], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.gains = gains
        self.isBuiltIn = isBuiltIn
    }

    private static func builtIn(_ name: String, _ gains: [Float]) -> EQPreset {
        EQPreset(id: "builtin." + name.lowercased().replacingOccurrences(of: " ", with: "-"), name: name, gains: gains, isBuiltIn: true)
    }

    //                                    32    64   125   250   500    1k    2k    4k    8k   16k
    public static let flat = builtIn("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])

    public static let builtIns: [EQPreset] = [
        flat,
        builtIn("Bass Boost",           [6, 5.5, 4.5, 3, 1, 0, 0, 0, 0, 0]),
        builtIn("Bass Reducer",         [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0]),
        builtIn("Treble Boost",         [0, 0, 0, 0, 0, 0.5, 1.5, 3, 4.5, 5.5]),
        builtIn("Vocal",                [-2, -2.5, -1.5, 0, 2, 3.5, 4, 3, 1.5, 0]),
        builtIn("Spoken Word",          [-3.5, -1, 0, 0.5, 3, 4.5, 4.5, 4, 2.5, 0]),
        builtIn("Loudness",             [5, 4, 2, 0, -1, -1, 0, 1, 3, 4]),
        builtIn("Laptop Speakers",      [-6, -2, 3, 3.5, 1, 0, 1, 2.5, 3, 2]),
        builtIn("Headphones",           [3, 2.5, 1, 0, -0.5, 0, 1, 2, 1.5, 1]),
        builtIn("Rock",                 [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        builtIn("Classical",            [4.5, 3.5, 3, 2.5, -1.5, -1.5, 0, 2, 3, 3.5]),
        builtIn("Pop",                  [-1, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        builtIn("Jazz",                 [4, 3, 1.5, 2, -1.5, -1.5, 0, 1.5, 3, 3.5]),
        builtIn("Electronic",           [4, 3.5, 1, 0, -2, 2, 1, 1, 4, 5]),
        builtIn("Hip-Hop",              [5, 4, 1.5, 3, -1, -1, 1, -0.5, 2, 3]),
        builtIn("Acoustic",             [4, 4, 3, 1, 1.5, 1.5, 3, 3.5, 3, 2]),
    ]
}
