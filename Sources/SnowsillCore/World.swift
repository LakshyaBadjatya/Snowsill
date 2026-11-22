import Foundation

/// Axis-aligned rectangle in global points, y down.
public struct Rect: Equatable, Sendable {
    public var x: Float, y: Float, w: Float, h: Float
    public init(x: Float, y: Float, w: Float, h: Float) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var minX: Float { x }
    public var maxX: Float { x + w }
    public var minY: Float { y }
    public var maxY: Float { y + h }
    @inline(__always) public func contains(_ px: Float, _ py: Float) -> Bool {
        px >= x && px < x + w && py >= y && py < y + h
    }
}

public struct WindowInfo: Equatable, Sendable {
    public var id: Int
    public var frame: Rect
    /// Belongs to an app the user exempted: no snow over it or on it.
    public var exempt: Bool
    /// A desktop widget or desktop icon (lives behind every app window).
    public var desktop: Bool
    public var cornerRadius: Float
    public init(id: Int, frame: Rect, exempt: Bool = false, desktop: Bool = false, cornerRadius: Float = 12) {
        self.id = id; self.frame = frame; self.exempt = exempt; self.desktop = desktop; self.cornerRadius = cornerRadius
    }
}

public struct ScreenInfo: Equatable, Sendable {
    public var id: Int
    public var frame: Rect
    /// The Dock platter, if the Dock is at the bottom of this screen.
    public var dock: Rect?
    /// Height of the menu bar strip at the top (0 if hidden).
    public var menuBar: Float
    public init(id: Int, frame: Rect, dock: Rect?, menuBar: Float = 0) {
        self.id = id; self.frame = frame; self.dock = dock; self.menuBar = menuBar
    }
    /// Where snow starts falling: just under the menu bar.
    public var skyTop: Float { frame.minY + menuBar }
}

public struct SimParams: Equatable, Sendable {
    public var precipitation: Precipitation = .snow
    public var intensity: Float = 0.5      // 0...1
    public var flakeScale: Float = 1       // 0.6...1.6
    public var pile: Float = 0.6           // 0...1 how much snow builds up
    public var melt: Float = 0.3           // 0...1
    public var wind: Float = 0             // -1...1
    public var fog: Float = 0              // 0...1
    public var pointer = true
    public var pileOnWindows = true
    public var pileOnDock = true
    /// Desktop widgets and (with Accessibility) desktop icons.
    public var pileOnDesktop = true
    /// Falling snow stays behind app windows (shows on the desktop only).
    public var desktopOnly = false
    public var icicles = true
    public var snowman = true
    public var frost = true
    /// Displays (ScreenInfo.id) where nothing falls.
    public var disabledScreens: Set<Int> = []
    /// Debug/testing: multiplies pile growth.
    public var pileBoost: Float = 1
    public init() {}
}

/// The whole simulation. Owned and stepped on the main thread.
public final class World {
    public var params = SimParams()
    public private(set) var particles = ParticleStore(capacity: 24_000)
    /// Active (drawable) surfaces: windows front→back, Docks, grounds.
    public private(set) var surfaces: [Surface] = []
    /// Window rects + Dock rects with their depth, front→back.
    public private(set) var occluders: [(rect: Rect, z: Float)] = []
    /// Windows of exempted apps: falling snow is hidden over them.
    public private(set) var exemptRects: [Rect] = []
    public private(set) var screens: [ScreenInfo] = []
    public let plow = Plow()
    /// 0...1: frost creeping in from the screen corners during long, heavy snow.
    public private(set) var frost: Float = 0

    public struct Snowman {
        public var screenIndex: Int
        public var x: Float
        /// 0...4 build stages (base, body, head, hat & arms).
        public var stage: Float
        public var alpha: Float
        public var height: Float
    }
    public private(set) var snowmen: [Snowman] = []
    private var snowmanTimer: Float = 0
    public private(set) var time: Float = 0
    /// Wind actually blowing this frame (gusts included), -1...1.
    public private(set) var windNow: Float = 0

    private var windowSurfaces: [Int: Surface] = [:]
    private var stashed: [Int: (surface: Surface, frame: Rect)] = [:]
    private var dying: [Surface] = []
    private var screenSurfaces: [Int: Surface] = [:]
    private var windowFrames: [Int: Rect] = [:]
    private var lastWindowsTime: Float = 0
    var rng = FastRandom(seed: 0xF1A5_C0DE)

    // Pointer
    private var pointerX: Float = -10_000, pointerY: Float = -10_000
    private var pointerVX: Float = 0, pointerVY: Float = 0
    public var pointerRadius: Float = 18

    // Spatial index of surfaces by x
    private let bucketW: Float = 128
    private var bucketOrigin: Float = 0
    private var buckets: [[Int32]] = []

    private var spawnCarry: [Int: Float] = [:]
    private var dripCarry: Float = 0

    public init() {}

    // MARK: - Inputs

    public func setScreens(_ newScreens: [ScreenInfo]) {
        screens = newScreens
        var next: [Int: Surface] = [:]
        for (si, s) in newScreens.enumerated() {
            let bottom = s.frame.maxY
            // Dock ledge
            if let d = s.dock {
                let id = -(1000 + si)
                if let old = screenSurfaces[id], old.kind == .dock {
                    if abs(old.width - d.w) > 0.5 || abs(old.minX - d.x) > 0.5 {
                        let spilled = old.resize(minX: d.x, width: d.w, anchor: .center)
                        spawnClumps(spilled, vx: 0, vy: 0)
                    }
                    old.reposition(minX: d.x, top: d.y)
                    next[id] = old
                } else {
                    next[id] = Surface(id: id, kind: .dock, minX: d.x, top: d.y, width: d.w,
                                       maxHeight: 20, cornerRadius: 16)
                }
            }
            // Ground: the screen bottom, split around the Dock.
            var segments: [(Float, Float)] = []
            if let d = s.dock {
                if d.minX - s.frame.minX > 10 { segments.append((s.frame.minX, d.minX - 4)) }
                if s.frame.maxX - d.maxX > 10 { segments.append((d.maxX + 4, s.frame.maxX)) }
            } else {
                segments.append((s.frame.minX, s.frame.maxX))
            }
            for (k, seg) in segments.enumerated() {
                let id = -(2000 + si * 4 + k)
                if let old = screenSurfaces[id], abs(old.minX - seg.0) < 0.5, abs(old.width - (seg.1 - seg.0)) < 0.5,
                   abs(old.top - bottom) < 0.5 {
                    next[id] = old
                } else {
                    let g = Surface(id: id, kind: .ground, minX: seg.0, top: bottom, width: seg.1 - seg.0,
                                    cellW: 2, maxHeight: 30)
                    if let old = screenSurfaces[id] {
                        // Keep what we can of the old ground snow.
                        for i in g.heights.indices {
                            let x = g.cellCenter(i)
                            if old.contains(x: x) { g.heights[i] = old.heights[old.cellIndex(x)] }
                        }
                    }
                    next[id] = g
                }
            }
        }
        screenSurfaces = next
        rebuildIndex()
    }

    /// Updates window ledges from the on-screen window list (front→back).
    /// - Parameters:
    ///   - offscreenAlive: ids of windows that left the screen but still exist
    ///     (minimized, other Space, hidden app): their snow is kept for later.
    ///   - silent: a Space switch or similar: no tumbling effects at all.
    public func setWindows(_ windows: [WindowInfo], offscreenAlive: Set<Int>, silent: Bool = false) {
        let dt = max(time - lastWindowsTime, 1.0 / 60)
        lastWindowsTime = time
        let n = windows.count
        var seen = Set<Int>()
        for (i, w) in windows.enumerated() {
            let f = w.frame
            seen.insert(w.id)
            let z = 0.08 + 0.84 * Float(i) / Float(max(n, 1))
            if let s = windowSurfaces[w.id] {
                let old = windowFrames[w.id] ?? f
                let sameSize = abs(old.w - f.w) < 0.5 && abs(old.h - f.h) < 0.5
                let dx = f.x - old.x, dy = f.y - old.y
                if sameSize {
                    if abs(dx) > 1.5 || abs(dy) > 1.5 {
                        // Moved: the snow stays behind and tumbles off.
                        if !silent {
                            spawnClumps(s.takeAll(), vx: dx / dt * 0.3, vy: min(dy / dt * 0.3, 0))
                            snapIcicles(s, vx: dx / dt * 0.3)
                        } else { _ = s.takeAll() }
                        s.reposition(minX: f.x, top: f.y)
                        s.bottom = f.maxY
                    }
                } else if abs(dy) > 1.5 {
                    // Resized from the top: the ledge itself moved.
                    if !silent { spawnClumps(s.takeAll(), vx: 0, vy: 0); snapIcicles(s, vx: 0) } else { _ = s.takeAll() }
                    _ = s.resize(minX: f.x, width: f.w)
                    s.reposition(minX: f.x, top: f.y)
                    s.bottom = f.maxY
                    s.seedIcicles()
                } else {
                    let spilled = s.resize(minX: f.x, width: f.w)
                    if !silent { spawnClumps(spilled, vx: 0, vy: 0); snapIcicles(s, vx: 0) }
                    s.reposition(minX: f.x, top: f.y)
                    if abs(f.maxY - s.bottom) > 1.5 && !silent { snapIcicles(s, vx: 0) }
                    s.bottom = f.maxY
                    s.seedIcicles()
                }
                s.z = z
                let accepts = !w.exempt && (!w.desktop || params.pileOnDesktop)
                if accepts != s.acceptsSnow {
                    s.acceptsSnow = accepts
                    if !accepts { _ = s.takeAll() }
                }
            } else if let st = stashed.removeValue(forKey: w.id) {
                let s = st.surface
                s.stashed = false
                if st.frame != f {
                    _ = s.takeAll()
                    _ = s.resize(minX: f.x, width: f.w)
                    s.reposition(minX: f.x, top: f.y)
                    s.bottom = f.maxY
                    s.seedIcicles()
                }
                s.z = z
                s.acceptsSnow = !w.exempt
                if w.exempt { _ = s.takeAll() }
                windowSurfaces[w.id] = s
            } else {
                let s = Surface(id: w.id, kind: .window, minX: f.x, top: f.y, width: f.w,
                                maxHeight: pileCap, cornerRadius: w.cornerRadius)
                s.bottom = f.maxY
                if !w.desktop { s.seedIcicles() }
                s.z = z
                s.acceptsSnow = !w.exempt && (!w.desktop || params.pileOnDesktop)
                windowSurfaces[w.id] = s
            }
            windowFrames[w.id] = f
        }
        for (id, s) in windowSurfaces where !seen.contains(id) {
            windowSurfaces[id] = nil
            if offscreenAlive.contains(id) || silent {
                s.stashed = true
                stashed[id] = (s, windowFrames[id] ?? Rect(x: s.minX, y: s.top, w: s.width, h: 0))
            } else {
                // Closed: some snow drops, the rest melts away quickly.
                windowFrames[id] = nil
                var drop: [Surface.Removed] = []
                for i in s.heights.indices where s.heights[i] > 1 {
                    let take = s.heights[i] * 0.35
                    s.heights[i] -= take
                    drop.append(.init(x: s.cellCenter(i), y: s.top - s.heights[i], volume: take * s.cellW))
                }
                spawnClumps(drop, vx: 0, vy: 0)
                snapIcicles(s, vx: 0)
                s.dying = true
                dying.append(s)
            }
        }
        exemptRects = windows.filter(\.exempt).map(\.frame)
        // Forget stashed windows that no longer exist at all.
        if !offscreenAlive.isEmpty || !stashed.isEmpty {
            for id in stashed.keys where !offscreenAlive.contains(id) && !seen.contains(id) {
                stashed[id] = nil
                windowFrames[id] = nil
            }
        }
        rebuildIndex()
    }

    /// Pointer in global points, sampled once per frame.
    public func setPointer(x: Float, y: Float, dt: Float) {
        guard dt > 0 else { return }
        if pointerX > -9_000 {
            let k = min(dt * 18, 1)
            pointerVX += ((x - pointerX) / dt - pointerVX) * k
            pointerVY += ((y - pointerY) / dt - pointerVY) * k
        }
        pointerX = x; pointerY = y
    }

    public func clearAll() {
        particles.removeAll()
        for s in allLiveSurfaces { _ = s.takeAll(); s.overflowLeft = 0; s.overflowRight = 0 }
        for st in stashed.values { _ = st.surface.takeAll() }
        dying.removeAll()
        snowmen.removeAll()
        frost = 0
        for s in surfaces { for k in s.icicles.indices { s.icicles[k].len = 0 } }
        plow.berm = 0
        rebuildIndex()
    }

    // MARK: - Derived

    var pileCap: Float { 4 + params.pile * 20 }

    private var allLiveSurfaces: [Surface] { Array(windowSurfaces.values) + Array(screenSurfaces.values) }

    /// True when nothing is moving: the renderer can stop presenting frames.
    public var isSettled: Bool {
        particles.count == 0 && params.precipitation == .none && params.fog < 0.01 && frost < 0.001
            && dying.isEmpty && !plow.isMoving
            && surfaces.allSatisfy { $0.quietFrames >= 90 }
    }

    public var hasAnySnow: Bool { surfaces.contains { !$0.isEmpty } }

    private func rebuildIndex() {
        // Order: windows front→back (by z), then Dock, then grounds; dying first so they draw.
        let wins = windowSurfaces.values.sorted { $0.z < $1.z }
        let screensS = screenSurfaces.values.sorted { $0.id > $1.id }
        for s in screensS { s.z = s.kind == .dock ? 0.02 : 0.99 }
        surfaces = dying + wins + screensS

        var occ: [(Rect, Float)] = []
        for sc in screens where sc.menuBar > 0 {
            occ.append((Rect(x: sc.frame.x, y: sc.frame.y, w: sc.frame.w, h: sc.menuBar), 0.01))
        }
        for s in screensS where s.kind == .dock {
            for sc in screens { if let d = sc.dock, abs(d.x - s.minX) < 1 { occ.append((d, 0.02)) } }
        }
        for s in wins {
            if let f = windowFrames[s.id] { occ.append((f, s.z)) }
        }
        occluders = occ.sorted { $0.1 < $1.1 }.map { (rect: $0.0, z: $0.1) }

        // Buckets
        guard let lo = surfaces.map(\.minX).min(), let hi = surfaces.map(\.maxX).max() else {
            buckets = []; return
        }
        bucketOrigin = lo
        let count = max(1, Int(((hi - lo) / bucketW).rounded(.up)) + 1)
        var b = Array(repeating: [Int32](), count: min(count, 4096))
        for (idx, s) in surfaces.enumerated() {
            let a = Int((s.minX - lo) / bucketW), z = Int((s.maxX - lo) / bucketW)
            for k in max(a, 0)...min(z, b.count - 1) { b[k].append(Int32(idx)) }
        }
        buckets = b
    }

    /// Is the point hidden behind something nearer than depth z?
    @inline(__always) func occluded(_ x: Float, _ y: Float, z: Float) -> Bool {
        for o in occluders {
            if o.z >= z - 1e-4 { break }
            if o.rect.contains(x, y) { return true }
        }
        return false
    }

    /// First visible ledge a particle crosses moving from y0 to y1 at x.
    @inline(__always) func landing(x: Float, y0: Float, y1: Float, forRain: Bool) -> Surface? {
        let bi = Int((x - bucketOrigin) / bucketW)
        guard bi >= 0, bi < buckets.count else { return nil }
        var best: Surface?
        var bestY = Float.greatestFiniteMagnitude
        for idx in buckets[bi] {
            let s = surfaces[Int(idx)]
            guard !s.dying, s.acceptsSnow, s.contains(x: x) else { continue }
            if !forRain {
                if s.kind == .window && !params.pileOnWindows { continue }
                if s.kind == .dock && !params.pileOnDock { continue }
            }
            let sy = s.surfaceY(atX: x)
            guard y0 <= sy + 0.5, y1 >= sy, sy < bestY else { continue }
            if occluded(x, sy - 0.5, z: s.z) { continue }
            best = s; bestY = sy
        }
        return best
    }

    // MARK: - Step

    public func step(dt rawDt: Float) {
        let dt = min(max(rawDt, 0), 1.0 / 20)
        guard dt > 0 else { return }
        time += dt
        // Gusty wind.
        let w = params.wind
        windNow = w * (1 + 0.3 * sin(time * 0.53) + 0.15 * sin(time * 1.37 + 2)) + 0.06 * sin(time * 0.21)

        spawn(dt: dt)
        integrate(dt: dt)
        interactPointer(dt: dt)
        updateSurfaces(dt: dt)
        plow.update(dt: dt, world: self)
    }

    private func spawn(dt: Float) {
        guard params.precipitation != .none, params.intensity > 0.001 else { return }
        let inten = params.intensity
        for s in screens where !params.disabledScreens.contains(s.id) {
            // Only spawn at the top of screens nothing is stacked above.
            let f = s.frame
            let stacked = screens.contains { o in o.id != s.id && abs(o.frame.maxY - f.minY) < 2 && o.frame.maxX > f.minX && o.frame.minX < f.maxX }
            if stacked { continue }
            switch params.precipitation {
            case .snow:
                let drift = windNow * 80 * (f.h / 50)
                let x0 = f.minX - max(drift, 0), x1 = f.maxX - min(drift, 0)
                let width = x1 - x0
                emit(key: s.id * 10 + 1, rate: inten * 0.075 * width, dt: dt) {
                    let size = self.rng.range(2.0, 4.4) * self.params.flakeScale
                    self.particles.add(kind: .near, x: self.rng.range(x0, x1), y: s.skyTop - self.rng.range(2, 24),
                                       vx: 0, vy: 40, size: size, alpha: self.rng.range(0.85, 1),
                                       phase: self.rng.range(0, 6.283))
                }
                emit(key: s.id * 10 + 2, rate: inten * 0.07 * width, dt: dt) {
                    let size = self.rng.range(0.8, 1.9) * self.params.flakeScale
                    self.particles.add(kind: .far, x: self.rng.range(x0, x1), y: s.skyTop - self.rng.range(2, 24),
                                       vx: 0, vy: 22, size: size, alpha: self.rng.range(0.3, 0.6),
                                       phase: self.rng.range(0, 6.283))
                }
            case .rain:
                let drift = windNow * 320 * (f.h / 1100)
                let x0 = f.minX - max(drift, 0), x1 = f.maxX - min(drift, 0)
                emit(key: s.id * 10 + 3, rate: inten * 0.55 * (x1 - x0), dt: dt) {
                    self.particles.add(kind: .rain, x: self.rng.range(x0, x1), y: s.skyTop - self.rng.range(0, 120),
                                       vx: self.windNow * 320, vy: self.rng.range(950, 1350),
                                       size: self.rng.range(0.9, 1.5), alpha: self.rng.range(0.35, 0.6))
                }
            case .none: break
            }
        }
        // Drips from window corners while raining.
        if params.precipitation == .rain {
            dripCarry += dt * inten * 0.5 * Float(windowSurfaces.count)
            while dripCarry >= 1 {
                dripCarry -= 1
                let wins = surfaces.filter { $0.kind == .window && !$0.dying }
                guard let s = wins.randomElement(using: &rngAdapter) else { break }
                let left = rng.chance(0.5)
                let x = left ? s.minX + 2.5 : s.maxX - 2.5
                let y = s.baseY(atX: x) + 1
                if !occluded(x, y, z: s.z) {
                    particles.add(kind: .drip, x: x, y: y, vx: 0, vy: 0, size: 0.6, alpha: 0.9,
                                  phase: 0, life: rng.range(0.4, 1.1))
                }
            }
        }
    }

    private var rngAdapter = SystemRandomNumberGenerator()

    @inline(__always) private func emit(key: Int, rate: Float, dt: Float, _ make: () -> Void) {
        var c = (spawnCarry[key] ?? rng.unit()) + rate * dt
        var n = 0
        while c >= 1, n < 400 { make(); c -= 1; n += 1 }
        spawnCarry[key] = c
    }

    private func integrate(dt: Float) {
        let t = time
        let wind = windNow
        let pr = params.pointer
        let px = pointerX, py = pointerY, pvx = pointerVX, pvy = pointerVY
        let repelR: Float = 70, repelR2 = repelR * repelR
        let pileBoost = (0.25 + params.pile * 1.5) * params.pileBoost
        var i = 0
        while i < particles.count {
            let k = particles.kind[i]
            var x = particles.x[i], y = particles.y[i]
            var vx = particles.vx[i], vy = particles.vy[i]
            let size = particles.size[i]
            let y0 = y
            var remove = false

            switch k {
            case .far, .near:
                let far = k == .far
                let ph = particles.phase[i]
                let fall: Float = far ? 16 + size * 9 : 30 + size * 8.5
                let swayAmp: Float = far ? 9 : 16 + size * 2
                let freq: Float = 0.6 + (ph.truncatingRemainder(dividingBy: 1)) * 0.9
                let targetVX = wind * (far ? 55 : 85) + sin(t * freq + ph) * swayAmp
                vx += (targetVX - vx) * min(dt * 1.6, 1)
                vy += (fall - vy) * min(dt * 1.2, 1)
                if pr {
                    let dx = x - px, dy = y - py
                    let d2 = dx * dx + dy * dy
                    if d2 < repelR2, d2 > 0.01 {
                        let d = d2.squareRoot()
                        let f = 1 - d / repelR
                        let push = (140 + (abs(pvx) + abs(pvy)) * 0.6) * f * f
                        vx += (dx / d * push + pvx * 0.9 * f) * dt * 3
                        vy += (dy / d * push + pvy * 0.9 * f) * dt * 3
                    }
                }
                x += vx * dt; y += vy * dt
                if !far, let s = landing(x: x, y0: y0, y1: y, forRain: false) {
                    s.deposit(x: x, volume: size * size * 0.55 * pileBoost)
                    remove = true
                }
            case .clump:
                vy = min(vy + 900 * dt, 480)
                vx *= max(1 - 1.2 * dt, 0)
                x += vx * dt; y += vy * dt
                if vy > 0, let s = landing(x: x, y0: y0, y1: y, forRain: false) {
                    s.deposit(x: x, volume: particles.life[i] * params.pileBoost.squareRoot())
                    remove = true
                }
            case .rain:
                vx += (wind * 320 - vx) * min(dt * 2, 1)
                x += vx * dt; y += vy * dt
                var hit = false
                var hy = y
                if pr {
                    let dx = x - px, dy = y - py
                    if dx * dx + dy * dy < 22 * 22, y0 < py { hit = true; hy = py - (22 * 22 - dx * dx).squareRoot() }
                }
                if !hit, let s = landing(x: x, y0: y0, y1: y, forRain: true) { hit = true; hy = s.surfaceY(atX: x) }
                if hit {
                    for _ in 0..<(rng.chance(0.5) ? 2 : 1) {
                        particles.add(kind: .splash, x: x, y: hy - 1, vx: rng.range(-70, 70) + vx * 0.1,
                                      vy: rng.range(-170, -60), size: rng.range(0.8, 1.4), alpha: 0.7,
                                      life: rng.range(0.18, 0.35))
                    }
                    remove = true
                }
            case .splash:
                vy += 1400 * dt
                x += vx * dt; y += vy * dt
                particles.life[i] -= dt
                if particles.life[i] <= 0 { remove = true }
            case .drip:
                if particles.life[i] > 0 {
                    particles.life[i] -= dt
                    particles.size[i] = min(size + dt * 2.4, 2.6)
                } else {
                    vy = min(vy + 1100 * dt, 900)
                    y += vy * dt
                }
            case .shard:
                vy = min(vy + 1300 * dt, 1100)
                x += vx * dt; y += vy * dt
                particles.phase[i] += vx * dt * 0.02
            case .spill:
                vy += 1500 * dt
                vx *= max(1 - 0.4 * dt, 0)
                x += vx * dt; y += vy * dt
                particles.phase[i] += dt * 9
            }

            if !remove, k == .spill, vy > 0, landsOnFloor(x, y) { remove = true }
            if !remove, !onScreen(x, y, kind: k) { remove = true }
            if remove {
                particles.remove(at: i)
            } else {
                particles.x[i] = x; particles.y[i] = y
                particles.vx[i] = vx; particles.vy[i] = vy
                i += 1
            }
        }
    }

    @inline(__always) private func onScreen(_ x: Float, _ y: Float, kind: ParticleKind) -> Bool {
        for s in screens {
            let f = s.frame
            if x >= f.minX - 240, x < f.maxX + 240, y >= f.minY - 400, y < f.maxY + 24 { return true }
        }
        return false
    }

    /// Plow spray falling back into the snow inside a screen.
    @inline(__always) private func landsOnFloor(_ x: Float, _ y: Float) -> Bool {
        for s in screens {
            let f = s.frame
            if x >= f.minX, x < f.maxX, y >= f.maxY - 3, y < f.maxY + 24 { return true }
        }
        return false
    }

    private func interactPointer(dt: Float) {
        guard params.pointer, pointerX > -9_000 else { return }
        let speed = (pointerVX * pointerVX + pointerVY * pointerVY).squareRoot()
        // Only a moving pointer pushes snow. A resting one would otherwise carve
        // every new flake that lands under it into a steady stream of clumps.
        guard speed > 30 else { return }
        let r = pointerRadius + min(speed * 0.01, 8)
        var budget = 260
        for s in surfaces where !s.dying && s.acceptsSnow {
            guard pointerX + r >= s.minX, pointerX - r <= s.maxX,
                  pointerY + r >= s.top - s.maxHeight - 4, pointerY - r <= s.top + 4 else { continue }
            if occluded(pointerX, s.top - 1, z: s.z) { continue }
            let removed = s.carve(cx: pointerX, cy: pointerY, r: r)
            guard !removed.isEmpty else { continue }
            let dir: Float = pointerVX >= 0 ? 1 : -1
            for rm in removed {
                var v = rm.volume
                // Part of it is shoved sideways, the rest is flicked into the air.
                if abs(pointerVX) > 40 {
                    let shove = v * 0.45
                    s.deposit(x: rm.x + dir * (r + 3), volume: shove)
                    v -= shove
                }
                while v > 0.5, budget > 0 {
                    let chunk = min(v, 4)
                    v -= chunk
                    budget -= 1
                    particles.add(kind: .clump, x: rm.x + rng.range(-1, 1), y: rm.y,
                                  vx: pointerVX * rng.range(0.25, 0.6) + rng.range(-35, 35),
                                  vy: min(pointerVY * 0.4, 0) - rng.range(50, 150),
                                  size: rng.range(1.5, 2.8), alpha: 1, life: chunk)
                }
            }
        }
    }

    private func updateSurfaces(dt: Float) {
        var meltRate: Float = 0.004 + params.melt * params.melt * 0.45
        if params.precipitation == .rain { meltRate += 0.25 * params.intensity + 0.05 }
        if params.precipitation == .none { meltRate += 0.02 }
        let cap = pileCap
        var budget = 240
        for s in surfaces where !s.dying {
            if s.kind == .window { s.maxHeight = cap } else if s.kind == .dock { s.maxHeight = cap * 1.1 }
            else { s.maxHeight = cap * 1.8 }
            s.relax(maxStep: s.kind == .ground ? 1.3 : 1.1, passes: 2)
            s.melt(meltRate * dt * (s.kind == .ground ? 0.7 : 1))
            // Snow sliding off the ends falls as clumps.
            // Snow sliding off a full ledge drops now and then as a clump (at most
            // one every ~1.5 s per end); the rest packs down. No waterfalls.
            let chunk: Float = 14
            s.shedTimerLeft -= dt; s.shedTimerRight -= dt
            if s.overflowLeft >= chunk, s.shedTimerLeft <= 0, budget > 0 {
                budget -= 1
                s.shedTimerLeft = rng.range(1.1, 2.2)
                particles.add(kind: .clump, x: s.minX - 1.5, y: s.baseY(atX: s.minX + 0.5) - 2,
                              vx: -rng.range(8, 30), vy: rng.range(-15, 5), size: rng.range(3.2, 4.4), life: chunk)
                s.overflowLeft = 0
            }
            if s.overflowRight >= chunk, s.shedTimerRight <= 0, budget > 0 {
                budget -= 1
                s.shedTimerRight = rng.range(1.1, 2.2)
                particles.add(kind: .clump, x: s.maxX + 1.5, y: s.baseY(atX: s.maxX - 0.5) - 2,
                              vx: rng.range(8, 30), vy: rng.range(-15, 5), size: rng.range(3.2, 4.4), life: chunk)
                s.overflowRight = 0
            }
            s.overflowLeft = min(s.overflowLeft, chunk * 2)
            s.overflowRight = min(s.overflowRight, chunk * 2)
        }
        updateIcicles(dt: dt, meltRate: meltRate)
        updateSnowmen(dt: dt)
        let heavy = params.precipitation == .snow && params.intensity > 0.55 && params.frost
        if plow.isVisible && plow.isAuto {
            // The plow's visit clears everything, frosty corners included.
            frost = max(frost - dt * 0.8, 0)
        } else {
            frost = heavy ? min(frost + dt / 90, 1) : max(frost - dt / (params.frost ? 45 : 2), 0)
        }

        // Closed windows: melt away fast, then vanish.
        if !dying.isEmpty {
            var changed = false
            for s in dying {
                s.scale(exp(-dt * 3.2))
                s.fade = max(s.fade - dt * 1.4, 0)
            }
            let before = dying.count
            dying.removeAll { $0.fade <= 0 || $0.isEmpty }
            changed = dying.count != before
            if changed { rebuildIndex() }
        }
    }

    // MARK: - Icicles

    private func updateIcicles(dt: Float, meltRate: Float) {
        let growing = params.icicles && (params.precipitation == .snow)
        for s in surfaces where s.kind == .window && !s.dying {
            guard !s.icicles.isEmpty else { continue }
            if !params.icicles {
                for k in s.icicles.indices { s.icicles[k].len = 0 }
                continue
            }
            let hasSnow = s.volume > s.width * 0.5
            // Icicles form from snowmelt dripping off a snowy ledge.
            let rate: Float = growing || hasSnow ? 0.12 * (0.4 + params.intensity) * params.pileBoost.squareRoot() : 0
            let shrink: Float = params.precipitation == .rain ? 0.6 : (growing || hasSnow ? 0 : meltRate * 3)
            for k in s.icicles.indices {
                var c = s.icicles[k]
                if rate > 0 { c.len = min(c.len + rate * dt * (0.6 + c.maxLen / 30), c.maxLen) }
                if shrink > 0 { c.len = max(c.len - shrink * dt, 0) }
                s.icicles[k] = c
            }
        }
    }

    func snapIcicles(_ s: Surface, vx: Float) {
        for k in s.icicles.indices where s.icicles[k].len > 2 {
            let c = s.icicles[k]
            particles.add(kind: .shard, x: s.minX + c.x, y: s.bottom + c.len * 0.5, vx: vx + rng.range(-20, 20),
                          vy: rng.range(-30, 20), size: c.width * 0.5, alpha: 0.9,
                          phase: rng.range(-0.3, 0.3), life: c.len)
            s.icicles[k].len = 0
        }
    }

    // MARK: - Snowman

    private func updateSnowmen(dt: Float) {
        // Existing snowmen build up while snow is around, and melt in the thaw.
        for k in snowmen.indices {
            if snowmen[k].stage < 4 {
                // Building: always finishes once started.
                snowmen[k].stage = min(snowmen[k].stage + dt / 7, 4)
                snowmen[k].alpha = min(snowmen[k].alpha + dt * 2, 1)
            } else if params.precipitation != .snow && params.melt > 0.05 {
                snowmen[k].alpha -= dt * params.melt * 0.02   // slow thaw
            }
        }
        snowmen.removeAll { $0.alpha <= 0 }
        guard params.snowman else { snowmen.removeAll(); return }
        snowmanTimer += dt
        guard snowmanTimer > 1 else { return }
        snowmanTimer = 0
        // A new snowman appears where the ground snow is deep enough to roll one.
        for (si, sc) in screens.enumerated() where !snowmen.contains(where: { $0.screenIndex == si }) {
            let grounds = surfaces.filter { $0.kind == .ground && $0.top == sc.frame.maxY && $0.width > 160 }
            for g in grounds {
                let span = 70 / g.cellW
                var best: (x: Float, d: Float)?
                var i = Int(span)
                while i < g.cellCount - Int(span) {
                    var sum: Float = 0
                    for j in (i - Int(span) / 2)..<(i + Int(span) / 2) { sum += g.heights[j] }
                    let avg = sum / span
                    if avg > 9, best == nil || avg > best!.d { best = (g.cellCenter(i), avg) }
                    i += Int(span) / 2
                }
                if let b = best, !(plow.isVisible && plow.screenIndex == si) {
                    // Rolling the balls uses up the snow around it.
                    _ = g.scrape(from: b.x - 40, to: b.x + 40)
                    snowmen.append(Snowman(screenIndex: si, x: b.x, stage: 0.2, alpha: 0.05, height: 74))
                    break
                }
            }
        }
    }

    /// The plow blade hit a snowman: it bursts into clumps.
    func knockSnowmen(screenIndex: Int, from x0: Float, to x1: Float, dir: Float, speed: Float) {
        let a = min(x0, x1), b = max(x0, x1)
        guard screenIndex < screens.count else { return }
        let ground = screens[screenIndex].frame.maxY
        snowmen.removeAll { m in
            guard m.screenIndex == screenIndex, m.x >= a, m.x <= b else { return false }
            let h = m.height * min(m.stage / 3, 1)
            for _ in 0..<70 {
                particles.add(kind: .clump, x: m.x + rng.range(-16, 16), y: ground - rng.range(2, max(h, 6)),
                              vx: dir * speed * rng.range(0.3, 0.9), vy: -rng.range(80, 300),
                              size: rng.range(2, 4.6), alpha: 1, phase: rng.range(0, 6), life: 6)
            }
            return true
        }
    }

    // MARK: - Helpers used by Plow

    func spawnClumps(_ removed: [Surface.Removed], vx: Float, vy: Float) {
        var total: Float = removed.reduce(0) { $0 + $1.volume }
        guard total > 0 else { return }
        // Cap particle count per event; big piles become bigger chunks.
        let maxParts: Float = 1400
        let chunk = max(4, total / maxParts)
        for r in removed {
            var v = r.volume
            while v > 0.3 {
                let c = min(v, chunk)
                v -= c; total -= c
                particles.add(kind: .clump, x: r.x + rng.range(-1, 1), y: r.y + rng.range(-1.5, 1.5),
                              vx: vx + rng.range(-28, 28), vy: vy - rng.range(0, 55),
                              size: min(1.4 + c.squareRoot() * 0.6, 4.5), alpha: 1, life: c)
            }
        }
    }

    func addParticle(kind: ParticleKind, x: Float, y: Float, vx: Float, vy: Float, size: Float, life: Float = 0) {
        particles.add(kind: kind, x: x, y: y, vx: vx, vy: vy, size: size, alpha: 1,
                      phase: rng.range(0, 6.283), life: life)
    }

    func random(_ a: Float, _ b: Float) -> Float { rng.range(a, b) }

    /// Flakes over an exempt window vanish (they would be drawn over it).
    @inline(__always) func overExempt(_ x: Float, _ y: Float) -> Bool {
        for r in exemptRects where r.contains(x, y) { return true }
        return false
    }

    /// Average snow depth (pt) along the bottom of a screen (ground + Dock).
    public func bottomDepth(screenIndex: Int) -> Float {
        guard screenIndex < screens.count else { return 0 }
        let ss = plowableSurfaces(screen: screens[screenIndex])
        let width = ss.reduce(Float(0)) { $0 + $1.width }
        guard width > 0 else { return 0 }
        return ss.reduce(Float(0)) { $0 + $1.volume } / width
    }

    /// Ledges the plow scrapes on a screen: its ground and Dock.
    func plowableSurfaces(screen: ScreenInfo) -> [Surface] {
        surfaces.filter { s in
            (s.kind == .ground || s.kind == .dock) && s.maxX > screen.frame.minX && s.minX < screen.frame.maxX
                && s.top <= screen.frame.maxY + 1 && s.top >= screen.frame.minY
        }
    }
}
