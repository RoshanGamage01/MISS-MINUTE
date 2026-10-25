import Foundation

/// Turns a stream of raw 16-bit little-endian mono PCM bytes (what streaming TTS endpoints send) into float
/// samples. Network chunks can split a sample in half; the odd byte is carried over to the next chunk.
public struct PCMStreamDecoder: Sendable {
    private var carry: UInt8?

    public init() {}

    public mutating func feed(_ data: Data) -> [Float] {
        var bytes = [UInt8](data)
        if let carry {
            bytes.insert(carry, at: 0)
            self.carry = nil
        }
        if bytes.count % 2 == 1 {
            carry = bytes.removeLast()
        }
        var samples = [Float](repeating: 0, count: bytes.count / 2)
        for i in 0..<samples.count {
            let value = Int16(bitPattern: UInt16(bytes[2 * i]) | (UInt16(bytes[2 * i + 1]) << 8))
            samples[i] = Float(value) / 32_768
        }
        return samples
    }

    /// Root-mean-square loudness of `samples`, scaled to roughly 0…1 for lip-sync.
    public static func level(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return min(1, Double((sum / Float(samples.count)).squareRoot()) * 4)
    }
}
