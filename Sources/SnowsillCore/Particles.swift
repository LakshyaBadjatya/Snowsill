/// Particle kinds. Raw values are read by the Metal shader.
public enum ParticleKind: UInt8 {
    /// Distant flake: small, slow, never lands (parallax depth).
    case far = 0
    /// Near flake: lands on ledges and builds piles.
    case near = 1
    /// Clump of settled snow knocked loose: falls fast, lands and re-piles.
    case clump = 2
    /// Raindrop streak.
    case rain = 3
    /// Splash droplet: short ballistic life.
    case splash = 4
    /// Water bead hanging from a window corner, then dropping.
    case drip = 5
    /// Plowed snow flung off the screen edge: never lands.
    case spill = 6
    /// A snapped-off icicle tumbling down (`life` holds its length).
    case shard = 7
}

/// Structure-of-arrays particle store with swap-remove. Fixed capacity so a
/// blizzard can never grow memory without bound.
public struct ParticleStore {
    public let capacity: Int
    public private(set) var count = 0
    public var x: [Float], y: [Float], vx: [Float], vy: [Float]
    public var size: [Float], phase: [Float], life: [Float], alpha: [Float]
    public var kind: [ParticleKind]

    public init(capacity: Int) {
        self.capacity = capacity
        x = .init(repeating: 0, count: capacity); y = x; vx = x; vy = x
        size = x; phase = x; life = x; alpha = x
        kind = .init(repeating: .far, count: capacity)
    }

    @discardableResult
    public mutating func add(kind k: ParticleKind, x px: Float, y py: Float, vx pvx: Float, vy pvy: Float,
                             size s: Float, alpha a: Float = 1, phase p: Float = 0, life l: Float = 0) -> Bool {
        guard count < capacity else { return false }
        let i = count
        x[i] = px; y[i] = py; vx[i] = pvx; vy[i] = pvy
        size[i] = s; alpha[i] = a; phase[i] = p; life[i] = l; kind[i] = k
        count += 1
        return true
    }

    public mutating func remove(at i: Int) {
        let last = count - 1
        if i != last {
            x[i] = x[last]; y[i] = y[last]; vx[i] = vx[last]; vy[i] = vy[last]
            size[i] = size[last]; phase[i] = phase[last]; life[i] = life[last]
            alpha[i] = alpha[last]; kind[i] = kind[last]
        }
        count -= 1
    }

    public mutating func removeAll() { count = 0 }

    public func count(of k: ParticleKind) -> Int {
        var n = 0
        for i in 0..<count where kind[i] == k { n += 1 }
        return n
    }
}
