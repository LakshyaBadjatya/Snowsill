import Foundation

/// The snow plow truck. It drives along the bottom of a screen. Swipe it (or
/// click it) and it lowers its blade, scrapes the ground and Dock snow into a
/// berm in front of the blade and shoves it off the side of the screen, where
/// the snow tumbles over the edge and drops away.
public final class Plow {
    public enum State: Equatable { case hidden, arriving, parked, dragging, plowing, leaving, waiting, returning }

    public private(set) var state: State = .hidden
    /// Left edge of the truck's box, global points.
    public private(set) var x: Float = 0
    /// Road level: the bottom of the screen.
    public private(set) var groundY: Float = 0
    /// +1 drives right (blade on the right), -1 drives left.
    public private(set) var facing: Float = 1
    public private(set) var vx: Float = 0
    public private(set) var length: Float = 176
    public private(set) var height: Float = 84
    /// Snow volume (pt²) riding in front of the blade.
    public var berm: Float = 0
    public private(set) var wheelAngle: Float = 0
    /// 0 = blade raised, 1 = blade on the ground (animated).
    public private(set) var blade: Float = 0
    public private(set) var screenIndex = 0
    /// Seconds since the truck appeared (beacon animation).
    public private(set) var clock: Float = 0

    private var parkX: Float = 0
    private var lastBladeX: Float?
    private var waitTimer: Float = 0
    private var dismissAfterExit = false
    private var dragStartPointer: Float = 0
    private var dragStartX: Float = 0
    private var dragSamples: [(t: Float, x: Float)] = []
    private var dragMoved: Float = 0
    /// Called automatically because the bottom got deep: clears, then drives away.
    public private(set) var isAuto = false
    private var passes = 0

    public init() {}

    public var isVisible: Bool { state != .hidden }
    public var isMoving: Bool { state != .hidden && state != .parked }
    public var bladeX: Float { facing > 0 ? x + length : x }
    public var frame: Rect { Rect(x: x, y: groundY - height, w: length, h: height) }

    /// Height and length of the snow mound in front of the blade.
    public var bermShape: (height: Float, length: Float) {
        let h = min(52, berm.squareRoot() * 0.85)
        return (h, min(80, h * 1.7 + 4))
    }

    // MARK: Commands

    /// Drives the truck in from the left edge of the given screen and parks it.
    public func spawn(screenIndex idx: Int, world: World, auto: Bool = false) {
        guard idx < world.screens.count else { return }
        let f = world.screens[idx].frame
        screenIndex = idx
        length = min(max(f.w * 0.092, 150), 230)
        height = length * 0.48
        groundY = f.maxY
        facing = 1
        x = f.minX - length - 20
        parkX = f.minX + 22
        vx = 0
        berm = 0
        blade = 0
        lastBladeX = nil
        dismissAfterExit = false
        clock = 0
        passes = 0
        isAuto = auto
        state = .arriving
    }

    /// Sends the truck away off the nearest edge.
    public func dismiss(world: World) {
        guard isVisible, screenIndex < world.screens.count else { return }
        let f = world.screens[screenIndex].frame
        facing = (x + length / 2) < (f.minX + f.maxX) / 2 ? -1 : 1
        dismissAfterExit = true
        state = .leaving
    }

    /// Removes the truck immediately (app turned off).
    public func dismissNow() { state = .hidden; berm = 0; vx = 0 }

    /// A trackpad swipe over the truck: plow in that direction.
    public func swipe(direction: Float, speed: Float) {
        guard isVisible, state == .parked || state == .arriving || state == .returning else { return }
        facing = direction >= 0 ? 1 : -1
        vx = facing * max(speed, 420)
        passes = 0
        lastBladeX = bladeX
        state = .plowing
    }

    public func beginDrag(pointerX px: Float, time: Float) {
        guard isVisible, state != .leaving else { return }
        state = .dragging
        dragStartPointer = px
        dragStartX = x
        dragSamples = [(time, px)]
        dragMoved = 0
        lastBladeX = bladeX
    }

    public func drag(pointerX px: Float, time: Float, world: World) {
        guard state == .dragging, screenIndex < world.screens.count else { return }
        let f = world.screens[screenIndex].frame
        let target = min(max(dragStartX + (px - dragStartPointer), f.minX - length * 0.75), f.maxX - length * 0.25)
        let dx = target - x
        dragMoved = max(dragMoved, abs(px - dragStartPointer))
        if abs(dx) > 0.5 {
            let dir: Float = dx > 0 ? 1 : -1
            if dir != facing { facing = dir; lastBladeX = bladeX }
        }
        x = target
        dragSamples.append((time, px))
        dragSamples.removeAll { time - $0.t > 0.12 }
    }

    public func endDrag(time: Float, world: World) {
        guard state == .dragging, screenIndex < world.screens.count else { return }
        var v: Float = 0
        if let first = dragSamples.first, let last = dragSamples.last, last.t - first.t > 0.005 {
            v = (last.x - first.x) / (last.t - first.t)
        }
        let f = world.screens[screenIndex].frame
        if dragMoved < 4 {
            // A click: plow toward the far side.
            facing = (x + length / 2) < (f.minX + f.maxX) / 2 ? 1 : -1
            vx = facing * 380
            passes = 0
            lastBladeX = bladeX
            state = .plowing
        } else if abs(v) > 140 {
            passes = 0
            facing = v > 0 ? 1 : -1
            vx = facing * max(abs(v), 420)
            lastBladeX = bladeX
            state = .plowing
        } else {
            // Slow drag released: stay here, drop the berm.
            parkX = x
            vx = 0
            state = .parked
        }
    }

    // MARK: Simulation

    func update(dt: Float, world: World) {
        guard state != .hidden else { return }
        guard screenIndex < world.screens.count else { state = .hidden; return }
        clock += dt
        let screen = world.screens[screenIndex]
        let f = screen.frame
        groundY = f.maxY

        let bladeTarget: Float = (state == .dragging || state == .plowing) ? 1 : 0
        blade += (bladeTarget - blade) * min(dt * 7, 1)

        let prevX = x
        switch state {
        case .hidden: break
        case .arriving, .returning:
            let dist = parkX - x
            let want = max(min(dist * 2.6, 300), -300)
            let minSpeed: Float = 28
            let v = abs(want) < minSpeed ? (dist >= 0 ? minSpeed : -minSpeed) : want
            if abs(dist) <= abs(v * dt) || abs(dist) < 0.4 {
                x = parkX; vx = 0; state = .parked
                if isAuto && state == .parked && passes == 0 {
                    // Auto run: go straight to work toward the far side.
                    facing = (x + length / 2) < (f.minX + f.maxX) / 2 ? 1 : -1
                    vx = facing * 420
                    lastBladeX = bladeX
                    state = .plowing
                }
            } else {
                vx = v; x += v * dt
            }
        case .parked:
            vx = 0
        case .dragging:
            vx = dt > 0 ? (x - prevX) / dt : 0
        case .plowing:
            let top: Float = 720
            vx += facing * 900 * dt
            vx = facing > 0 ? min(vx, max(top, vx - 400 * dt)) : max(vx, min(-top, vx + 400 * dt))
            if facing * vx < 120 { vx = facing * 120 }
            x += vx * dt
            if (facing > 0 && x > f.maxX + 40) || (facing < 0 && x + length < f.minX - 40) {
                passes += 1
                state = .waiting; waitTimer = 0.7; vx = 0
            }
        case .leaving:
            vx += facing * 600 * dt
            if facing * vx < 160 { vx = facing * 160 }
            x += vx * dt
            if (facing > 0 && x > f.maxX + 40) || (facing < 0 && x + length < f.minX - 40) {
                if dismissAfterExit { state = .hidden; berm = 0; return }
                state = .waiting; waitTimer = 0.9; vx = 0
            }
        case .waiting:
            waitTimer -= dt
            if waitTimer <= 0 {
                let exitedRight = x > (f.minX + f.maxX) / 2
                facing = exitedRight ? -1 : 1
                x = exitedRight ? f.maxX + 20 : f.minX - length - 20
                berm = 0
                let remaining = world.plowableSurfaces(screen: screen).reduce(Float(0)) { $0 + $1.volume }
                if remaining > 150, passes < 3 {
                    // Snow left behind (e.g. where it was parked): plow back the other way.
                    vx = facing * 520
                    lastBladeX = bladeX
                    state = .plowing
                } else if isAuto {
                    state = .hidden
                    isAuto = false
                } else {
                    // Come back in from the side it left, turned around, blade up.
                    parkX = exitedRight ? f.maxX - length - 22 : f.minX + 22
                    lastBladeX = nil
                    passes = 0
                    state = .returning
                }
            }
        }
        wheelAngle += (x - prevX) / (height * 0.17)

        // Blade work.
        if state == .dragging || state == .plowing {
            let b = bladeX
            if let lb = lastBladeX, abs(b - lb) > 0.01 {
                let (a, z) = facing > 0 ? (lb, b) : (b, lb)
                for s in world.plowableSurfaces(screen: screen) where s.top >= groundY - height * 1.25 {
                    berm += s.scrape(from: a - (facing > 0 ? 0 : bermShape.length), to: z + (facing > 0 ? bermShape.length : 0))
                }
                world.knockSnowmen(screenIndex: screenIndex, from: a, to: z, dir: facing, speed: max(abs(vx), 200))
            }
            lastBladeX = b
            sprayAndSpill(dt: dt, world: world, frame: f)
        } else {
            lastBladeX = nil
            if berm > 1, state == .parked {
                // Stopped: leave the mound where it is.
                let g = world.plowableSurfaces(screen: screen).filter { $0.kind == .ground }
                let front = bladeX + facing * bermShape.length * 0.5
                if let s = g.first(where: { $0.contains(x: front) }) {
                    var left = berm
                    var k: Float = 0
                    while left > 0.5, k < 40 {
                        let piece = min(left, max(berm / 12, 2))
                        s.deposit(x: front + facing * (k - 6) * 3, volume: piece)
                        left -= piece; k += 1
                    }
                }
                berm = 0
            }
        }
    }

    private func sprayAndSpill(dt: Float, world: World, frame f: Rect) {
        let speed = abs(vx)
        let shape = bermShape
        let b = bladeX
        let edge = facing > 0 ? f.maxX : f.minX
        let pastEdge = facing > 0 ? (b + shape.length * 0.4 >= edge) : (b - shape.length * 0.4 <= edge)
        if pastEdge, berm > 0 {
            // Snow pours over the side of the screen and drops away. Once the
            // blade itself is past the edge, everything left goes at once.
            let bladeGone = facing > 0 ? b >= edge : b <= edge
            let release = bladeGone ? berm : min(berm, max(berm * dt * 9, 160 * dt))
            berm -= release
            var v = release
            var n = 0
            let chunk = max(6, release / 220)
            while v > 0.2, n < 240 {
                let c = min(v, chunk)
                v -= c; n += 1
                world.addParticle(kind: .spill, x: edge - facing * world.random(0, 12),
                                  y: groundY - world.random(2, max(shape.height, 6) + 4),
                                  vx: facing * max(speed, 260) * world.random(0.45, 0.95),
                                  vy: -world.random(80, 330), size: world.random(2.2, 5.2), life: c)
            }
        } else if berm > 25, speed > 90 {
            // Cosmetic spray rolling off the top of the berm; it falls back
            // into the snow, so the berm keeps its volume.
            let rate = min(berm / 400, 1) * min(speed / 500, 1) * 70
            let count = Int(rate * dt + world.random(0, 1))
            for _ in 0..<count {
                world.addParticle(kind: .spill, x: b + facing * world.random(0, shape.length * 0.7),
                                  y: groundY - shape.height - world.random(0, 4),
                                  vx: vx * world.random(0.95, 1.25), vy: -world.random(60, 190),
                                  size: world.random(1.6, 3.2), life: 0)
            }
        }
    }
}
