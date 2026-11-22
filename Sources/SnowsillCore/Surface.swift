import Foundation

/// A horizontal ledge snow can settle on: the top edge of a window, the top of
/// the Dock, or the bottom of a screen. Snow is a 1-D heightfield: one column
/// every `cellW` points. Coordinates are global points, y grows downward
/// (CoreGraphics window-list space).
public final class Surface {
    public enum Kind: Equatable { case window, dock, ground }

    public let id: Int
    public let kind: Kind
    public private(set) var minX: Float
    public private(set) var top: Float
    public private(set) var width: Float
    public let cellW: Float
    public var heights: [Float]
    /// Pile cap in points.
    public var maxHeight: Float
    /// Window corner radius: the pile's base follows the rounded corner.
    public var cornerRadius: Float
    /// Depth for rendering/occlusion: smaller is nearer the viewer.
    public var z: Float = 0.5
    /// Render opacity (fades while a closed window's snow melts away).
    public var fade: Float = 1
    /// Window closed: its snow is melting away; removed when empty.
    public var dying = false
    /// Window exists but is not on screen (minimized / other Space): keep the snow, draw nothing.
    public var stashed = false
    /// False for windows of exempted apps.
    public var acceptsSnow = true
    /// Windows: y of the bottom edge, where icicles hang.
    public var bottom: Float = 0

    public struct Icicle {
        /// Offset from the window's left edge.
        public var x: Float
        public var len: Float
        public var maxLen: Float
        public var width: Float
    }
    public var icicles: [Icicle] = []

    /// Lays out icicles along the bottom edge (deterministic per window).
    public func seedIcicles() {
        var rng = FastRandom(seed: UInt64(truncatingIfNeeded: id &* 2_654_435_761) | 1)
        icicles.removeAll()
        var x = cornerRadius + rng.range(4, 14)
        while x < width - cornerRadius - 4 {
            if rng.chance(0.8) {
                icicles.append(Icicle(x: x, len: 0, maxLen: rng.range(5, 26), width: rng.range(2.6, 5.5)))
            }
            x += rng.range(14, 40)
        }
    }
    /// Ends that shed snow. Ground segments at a screen edge keep it (a wall).
    public var shedsLeft = true
    public var shedsRight = true
    /// Snow that slid off each end, waiting to be spawned as falling clumps.
    public var overflowLeft: Float = 0
    public var overflowRight: Float = 0
    /// Seconds until each end may drop its next clump.
    var shedTimerLeft: Float = 0
    var shedTimerRight: Float = 0
    /// Frames since anything changed; settled surfaces skip relaxation.
    var quietFrames = 0

    public var maxX: Float { minX + width }
    public var cellCount: Int { heights.count }

    public init(id: Int, kind: Kind, minX: Float, top: Float, width: Float,
                cellW: Float = 2, maxHeight: Float = 16, cornerRadius: Float = 0) {
        self.id = id
        self.kind = kind
        self.minX = minX
        self.top = top
        self.width = max(width, cellW)
        self.cellW = cellW
        self.maxHeight = maxHeight
        self.cornerRadius = cornerRadius
        heights = Array(repeating: 0, count: max(1, Int((max(width, cellW) / cellW).rounded(.up))))
        if kind == .ground { shedsLeft = false; shedsRight = false }
    }

    // MARK: Geometry

    @inline(__always) public func contains(x: Float) -> Bool { x >= minX && x < maxX }

    @inline(__always) public func cellIndex(_ x: Float) -> Int {
        min(max(Int((x - minX) / cellW), 0), heights.count - 1)
    }

    @inline(__always) public func cellCenter(_ i: Int) -> Float { minX + (Float(i) + 0.5) * cellW }

    /// How far below `top` the ledge is at x (rounded window corners).
    @inline(__always) public func cornerDrop(atX x: Float) -> Float {
        let r = cornerRadius
        guard r > 0 else { return 0 }
        let d = min(x - minX, maxX - x)
        guard d < r else { return 0 }
        let e = r - max(d, 0)
        return r - (r * r - e * e).squareRoot()
    }

    @inline(__always) public func baseY(atX x: Float) -> Float { top + cornerDrop(atX: x) }

    /// Pile height at x, linearly interpolated between column centers.
    public func height(atX x: Float) -> Float {
        let f = (x - minX) / cellW - 0.5
        let i0 = Int(f.rounded(.down))
        let t = f - Float(i0)
        let n = heights.count
        let a = heights[min(max(i0, 0), n - 1)]
        let b = heights[min(max(i0 + 1, 0), n - 1)]
        return a + (b - a) * t
    }

    /// The y of the snow's upper surface (or the bare ledge) at x.
    @inline(__always) public func surfaceY(atX x: Float) -> Float { baseY(atX: x) - height(atX: x) }

    /// Total snow volume (pt²) on this surface.
    public var volume: Float { heights.reduce(0, +) * cellW }

    public var isEmpty: Bool { heights.allSatisfy { $0 < 0.05 } }

    // MARK: Changes

    /// Adds `volume` pt² of snow around x. Returns the volume actually kept.
    @discardableResult
    public func deposit(x: Float, volume: Float) -> Float {
        guard volume > 0 else { return 0 }
        let i = cellIndex(x)
        let dh = volume / cellW
        var kept: Float = 0
        // Spread 25/50/25 so single flakes don't make spikes.
        for (offset, w) in [(-1, Float(0.25)), (0, 0.5), (1, 0.25)] {
            let j = i + offset
            guard j >= 0, j < heights.count else {
                // Off the end: that share slides off.
                if j < 0 { overflowLeft += dh * w * cellW } else { overflowRight += dh * w * cellW }
                continue
            }
            let room = max(maxHeight - heights[j], 0)
            let add = min(dh * w, room)
            heights[j] += add
            kept += add * cellW
        }
        quietFrames = 0
        return kept
    }

    /// Lets steep slopes slide (angle of repose). `maxStep` is the largest
    /// allowed height difference between neighbouring columns. Snow pushed past
    /// a shedding end goes to `overflowLeft/Right`. Volume is conserved.
    public func relax(maxStep: Float, passes: Int = 2) {
        let n = heights.count
        guard n > 0, quietFrames < 90 else { return }
        var moved: Float = 0
        heights.withUnsafeMutableBufferPointer { h in
            for pass in 0..<passes {
                let forward = pass % 2 == 0
                var k = 0
                while k < n - 1 {
                    let i = forward ? k : n - 2 - k
                    // Compare snow surfaces, not raw heights: corners slope down.
                    let ei = h[i] - cornerDrop(atX: cellCenter(i))
                    let ej = h[i + 1] - cornerDrop(atX: cellCenter(i + 1))
                    let d = ei - ej
                    if d > maxStep {
                        let m = min((d - maxStep) * 0.5, h[i])
                        h[i] -= m; h[i + 1] += m; moved += m
                    } else if d < -maxStep {
                        let m = min((-d - maxStep) * 0.5, h[i + 1])
                        h[i + 1] -= m; h[i] += m; moved += m
                    }
                    k += 1
                }
                if shedsLeft, h[0] > maxStep {
                    let m = (h[0] - maxStep) * 0.5
                    h[0] -= m; overflowLeft += m * cellW; moved += m
                }
                if shedsRight, h[n - 1] > maxStep {
                    let m = (h[n - 1] - maxStep) * 0.5
                    h[n - 1] -= m; overflowRight += m * cellW; moved += m
                }
            }
        }
        quietFrames = moved > 0.001 ? 0 : quietFrames + 1
    }

    /// Melts `amount` points of height everywhere.
    public func melt(_ amount: Float) {
        guard amount > 0 else { return }
        var any = false
        for i in heights.indices where heights[i] > 0 {
            heights[i] = max(heights[i] - amount, 0)
            any = true
        }
        if any { quietFrames = 0 }
    }

    /// Scales all snow (used for fast melt-away of a closed window).
    public func scale(_ f: Float) {
        for i in heights.indices { heights[i] *= f }
    }

    public struct Removed { public var x: Float; public var y: Float; public var volume: Float }

    /// Cuts a circle (the pointer) out of the pile. Snow above and inside the
    /// circle is removed and returned per column so the caller can fling it.
    public func carve(cx: Float, cy: Float, r: Float) -> [Removed] {
        guard cx + r >= minX, cx - r <= maxX else { return [] }
        var out: [Removed] = []
        let i0 = cellIndex(cx - r), i1 = cellIndex(cx + r)
        for i in i0...i1 {
            let x = cellCenter(i)
            let dx = x - cx
            guard abs(dx) < r, heights[i] > 0.01 else { continue }
            let s = (r * r - dx * dx).squareRoot()
            let base = baseY(atX: x)
            let pileTop = base - heights[i]
            // Circle overlaps the pile column?
            guard cy + s > pileTop, cy - s < base else { continue }
            let newH = max(0, min(heights[i], base - (cy + s)))
            let cut = heights[i] - newH
            if cut > 0.01 {
                out.append(Removed(x: x, y: pileTop + cut * 0.5, volume: cut * cellW))
                heights[i] = newH
            }
        }
        if !out.isEmpty { quietFrames = 0 }
        return out
    }

    /// Removes all snow in [x0, x1) and returns its volume (the plow blade).
    public func scrape(from x0: Float, to x1: Float) -> Float {
        let a = min(x0, x1), b = max(x0, x1)
        guard b > minX, a < maxX else { return 0 }
        var v: Float = 0
        for i in cellIndex(a)...cellIndex(b) {
            let c = cellCenter(i)
            guard c >= a, c < b else { continue }
            v += heights[i] * cellW
            heights[i] = 0
        }
        if v > 0 { quietFrames = 0 }
        return v
    }

    /// Moves the ledge without touching the snow (e.g. z-order refresh).
    public func reposition(minX: Float, top: Float) {
        self.minX = minX
        self.top = top
    }

    public enum Anchor { case left, right, center }

    /// Changes the width keeping the side that did not move. Returns snow from
    /// columns that no longer exist, with their x positions, so it can fall.
    public func resize(minX newMinX: Float, width newWidth: Float, anchor: Anchor? = nil) -> [Removed] {
        let newCount = max(1, Int((max(newWidth, cellW) / cellW).rounded(.up)))
        var spilled: [Removed] = []
        let a: Anchor = anchor ?? (abs(newMinX - minX) < 0.5 ? .left : .right)
        let shift: Int
        switch a {
        case .left: shift = 0
        case .right: shift = heights.count - newCount
        case .center: shift = (heights.count - newCount) / 2
        }
        var newHeights = Array(repeating: Float(0), count: newCount)
        for i in 0..<heights.count {
            let j = i - shift
            if j >= 0, j < newCount { newHeights[j] = heights[i] } else if heights[i] > 0.01 {
                spilled.append(Removed(x: cellCenter(i), y: top - heights[i] * 0.5, volume: heights[i] * cellW))
            }
        }
        minX = newMinX
        width = max(newWidth, cellW)
        heights = newHeights
        quietFrames = 0
        return spilled
    }

    /// Takes all the snow off (returns it per column, for tumbling).
    public func takeAll() -> [Removed] {
        var out: [Removed] = []
        for i in heights.indices where heights[i] > 0.05 {
            let x = cellCenter(i)
            out.append(Removed(x: x, y: baseY(atX: x) - heights[i] * 0.5, volume: heights[i] * cellW))
            heights[i] = 0
        }
        quietFrames = 0
        return out
    }
}
