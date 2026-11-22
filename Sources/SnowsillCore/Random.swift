/// Small, fast, deterministic RNG (xorshift64). Deterministic so tests are stable.
public struct FastRandom {
    private var state: UInt64

    public init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        state = seed == 0 ? 0x1234_5678 : seed
    }

    @inline(__always) public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// Uniform in [0, 1).
    @inline(__always) public mutating func unit() -> Float {
        Float(next() >> 40) * (1.0 / 16_777_216.0)
    }

    /// Uniform in [a, b).
    @inline(__always) public mutating func range(_ a: Float, _ b: Float) -> Float {
        a + (b - a) * unit()
    }

    @inline(__always) public mutating func chance(_ p: Float) -> Bool { unit() < p }
}
