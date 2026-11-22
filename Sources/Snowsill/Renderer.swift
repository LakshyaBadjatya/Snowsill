import AppKit
import Metal
import MetalKit
import QuartzCore
import simd
import SnowsillCore

struct Uniforms {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var scale: Float
    var time: Float
    var fog: Float
    var wind: Float
    /// Depth of falling snow and fog: in front of everything, or behind windows.
    var pz: Float
    var frost: Float
}

struct ParticleInstance {
    var pos: SIMD2<Float>
    var vel: SIMD2<Float>
    var size: Float
    var alpha: Float
    var kind: Float
    var phase: Float
}

struct PileVertex {
    var pos: SIMD2<Float>
    var z: Float
    var depth: Float
    var thick: Float
    var alpha: Float
}

struct OccVertex {
    var pos: SIMD2<Float>
    var z: Float
    var pad: Float = 0
}

struct TruckQuad {
    var center: SIMD2<Float>
    var half: SIMD2<Float>
    var angle: Float
    var flip: Float
    var alpha: Float
    var kind: Float
}

/// Device, pipelines and textures shared by every screen's overlay.
final class MetalShared {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let particlePipe: MTLRenderPipelineState
    let pilePipe: MTLRenderPipelineState
    let occPipe: MTLRenderPipelineState
    let fogPipe: MTLRenderPipelineState
    let truckPipe: MTLRenderPipelineState
    let frostPipe: MTLRenderPipelineState
    let depthWrite: MTLDepthStencilState
    let depthTest: MTLDepthStencilState
    let depthOff: MTLDepthStencilState
    let truck: TruckTextures
    let snowman: SnowmanTextures

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: shaderSource, options: nil) } catch {
            NSLog("Snowsill: shader compile failed: \(error)")
            return nil
        }
        func pipe(_ v: String, _ f: String?, color: Bool = true) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = f.flatMap { lib.makeFunction(name: $0) }
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            if color {
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            } else {
                c.writeMask = []
            }
            d.depthAttachmentPixelFormat = .depth32Float
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let pp = pipe("particleV", "particleF"), let pl = pipe("pileV", "pileF"),
              let oc = pipe("occV", nil, color: false), let fg = pipe("fogV", "fogF"),
              let tr = pipe("truckV", "truckF"), let fr = pipe("fogV", "frostF") else { return nil }
        particlePipe = pp; pilePipe = pl; occPipe = oc; fogPipe = fg; truckPipe = tr; frostPipe = fr

        let w = MTLDepthStencilDescriptor()
        w.depthCompareFunction = .less
        w.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: w)!
        let t = MTLDepthStencilDescriptor()
        t.depthCompareFunction = .less
        t.isDepthWriteEnabled = false
        depthTest = device.makeDepthStencilState(descriptor: t)!
        let o = MTLDepthStencilDescriptor()
        o.depthCompareFunction = .always
        o.isDepthWriteEnabled = false
        depthOff = device.makeDepthStencilState(descriptor: o)!
        truck = TruckTextures(device: device)
        snowman = SnowmanTextures(device: device)
    }
}

/// Draws the world into one screen's CAMetalLayer.
final class OverlayRenderer {
    let shared: MetalShared
    let layer: CAMetalLayer
    private let inFlight = DispatchSemaphore(value: 3)
    private var slot = 0
    private var particleBufs: [MTLBuffer] = []
    private var pileBufs: [MTLBuffer?] = [nil, nil, nil]
    private var occBufs: [MTLBuffer?] = [nil, nil, nil]
    private var truckBufs: [MTLBuffer] = []
    private var depthTex: MTLTexture?
    private let maxParticles = 24_000

    init(shared: MetalShared, layer: CAMetalLayer) {
        self.shared = shared
        self.layer = layer
        layer.device = shared.device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        layer.backgroundColor = NSColor.clear.cgColor
        for _ in 0..<3 {
            particleBufs.append(shared.device.makeBuffer(length: MemoryLayout<ParticleInstance>.stride * maxParticles,
                                                         options: .storageModeShared)!)
            truckBufs.append(shared.device.makeBuffer(length: MemoryLayout<TruckQuad>.stride * 16,
                                                      options: .storageModeShared)!)
        }
    }

    private func ensure(_ buf: inout MTLBuffer?, bytes: Int) -> MTLBuffer {
        if let b = buf, b.length >= bytes { return b }
        let b = shared.device.makeBuffer(length: max(bytes * 3 / 2, 4096), options: .storageModeShared)!
        buf = b
        return b
    }

    /// Renders one frame. `screen` is this overlay's rect in global points (y down).
    /// Renders one frame. With `offscreen`, draws into that texture and waits
    /// for the GPU (used for screenshots) instead of presenting to the screen.
    func render(world: World, screen: Rect, scale: Float, offscreen: MTLTexture? = nil) {
        let pixelW = Int(screen.w * scale), pixelH = Int(screen.h * scale)
        guard pixelW > 0, pixelH > 0 else { return }
        if offscreen == nil, layer.drawableSize.width != CGFloat(pixelW) || layer.drawableSize.height != CGFloat(pixelH) {
            layer.drawableSize = CGSize(width: pixelW, height: pixelH)
        }
        if depthTex == nil || depthTex!.width != pixelW || depthTex!.height != pixelH {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: pixelW, height: pixelH, mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = .memoryless
            depthTex = shared.device.makeTexture(descriptor: d)
        }
        // Never block the main thread waiting on the GPU: drop the frame instead.
        guard inFlight.wait(timeout: offscreen == nil ? .now() : .distantFuture) == .success else { return }
        let drawable = offscreen == nil ? layer.nextDrawable() : nil
        guard let target = offscreen ?? drawable?.texture else { inFlight.signal(); return }
        slot = (slot + 1) % 3

        var u = Uniforms(origin: SIMD2(screen.x, screen.y), size: SIMD2(screen.w, screen.h), scale: scale,
                         time: world.time, fog: world.params.fog, wind: world.windNow,
                         pz: world.params.desktopOnly ? 0.995 : 0.004, frost: world.frost)

        // --- Fill buffers ---
        let pCount = fillParticles(world: world, screen: screen, into: particleBufs[slot])
        let (pileBuf, pileCount) = fillPiles(world: world, screen: screen)
        let (occBuf, occCount) = fillOccluders(world: world, screen: screen)
        let needOcc = world.params.desktopOnly || !world.exemptRects.isEmpty
        let tCount = fillTruck(world: world, screen: screen, into: truckBufs[slot])

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        rp.depthAttachment.texture = depthTex
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1
        rp.depthAttachment.storeAction = .dontCare

        guard let cb = shared.queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rp) else {
            inFlight.signal(); return
        }
        let ub = MemoryLayout<Uniforms>.stride

        // Depth: window/Dock/menu-bar rects (piles behind them hide), plus
        // exempt windows pulled to the very front so no snow falls over them.
        if (pileCount > 0 || needOcc || u.fog > 0.005), occCount > 0, let ob = occBuf {
            enc.setRenderPipelineState(shared.occPipe)
            enc.setDepthStencilState(shared.depthWrite)
            enc.setVertexBuffer(ob, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: ub, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: occCount)
        }
        if u.fog > 0.005 {
            enc.setRenderPipelineState(shared.fogPipe)
            enc.setDepthStencilState(needOcc ? shared.depthTest : shared.depthOff)
            enc.setVertexBytes(&u, length: ub, index: 1)
            enc.setFragmentBytes(&u, length: ub, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if pileCount > 0 {
            enc.setRenderPipelineState(shared.pilePipe)
            enc.setDepthStencilState(shared.depthTest)
            enc.setVertexBuffer(pileBuf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: ub, index: 1)
            enc.setFragmentBytes(&u, length: ub, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: pileCount)
        }
        if tCount > 0 {
            drawTruck(enc: enc, u: &u, count: tCount, buf: truckBufs[slot], pileBuf: nil)
        }
        if u.frost > 0.002 {
            enc.setRenderPipelineState(shared.frostPipe)
            enc.setDepthStencilState(needOcc ? shared.depthTest : shared.depthOff)
            enc.setVertexBytes(&u, length: ub, index: 1)
            enc.setFragmentBytes(&u, length: ub, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if pCount > 0 {
            enc.setRenderPipelineState(shared.particlePipe)
            enc.setDepthStencilState(needOcc ? shared.depthTest : shared.depthOff)
            enc.setVertexBuffer(particleBufs[slot], offset: 0, index: 0)
            enc.setVertexBytes(&u, length: ub, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: pCount)
        }
        enc.endEncoding()
        let sem = inFlight
        cb.addCompletedHandler { _ in sem.signal() }
        if let drawable { cb.present(drawable) }
        cb.commit()
        if offscreen != nil { cb.waitUntilCompleted() }
    }

    // MARK: Buffer fill

    private func fillParticles(world: World, screen: Rect, into buf: MTLBuffer) -> Int {
        let ps = world.particles
        let out = buf.contents().bindMemory(to: ParticleInstance.self, capacity: maxParticles)
        let x0 = screen.minX - 40, x1 = screen.maxX + 40, y0 = screen.minY - 40, y1 = screen.maxY + 40
        var n = 0
        ps.x.withUnsafeBufferPointer { xs in
            ps.y.withUnsafeBufferPointer { ys in
                for i in 0..<ps.count {
                    let x = xs[i], y = ys[i]
                    guard x > x0, x < x1, y > y0, y < y1 else { continue }
                    let k = ps.kind[i]
                    let vel = k == .shard ? SIMD2(ps.life[i], 0) : SIMD2(ps.vx[i], ps.vy[i])
                    out[n] = ParticleInstance(pos: SIMD2(x, y), vel: vel, size: ps.size[i],
                                              alpha: ps.alpha[i], kind: Float(k.rawValue), phase: ps.phase[i])
                    n += 1
                    if n == maxParticles { return }
                }
            }
        }
        return n
    }

    private var pileScratch: [PileVertex] = []

    private func fillPiles(world: World, screen: Rect) -> (MTLBuffer?, Int) {
        pileScratch.removeAll(keepingCapacity: true)
        for s in world.surfaces where !s.stashed {
            guard s.maxX > screen.minX, s.minX < screen.maxX,
                  s.top > screen.minY - 4, s.top - s.maxHeight < screen.maxY + 4 else { continue }
            appendSurface(s, screen: screen)
            if s.kind == .window, !s.icicles.isEmpty, s.bottom > screen.minY, s.bottom < screen.maxY + 30 {
                let z = max(s.z - 0.002, 0)
                for c in s.icicles where c.len > 0.4 {
                    let x = s.minX + c.x, hw = c.width * 0.5 * min(c.len / 6, 1)
                    pileScratch.append(PileVertex(pos: SIMD2(x - hw, s.bottom - 0.5), z: z, depth: 0, thick: c.len, alpha: -s.fade))
                    pileScratch.append(PileVertex(pos: SIMD2(x + hw, s.bottom - 0.5), z: z, depth: 0, thick: c.len, alpha: -s.fade))
                    pileScratch.append(PileVertex(pos: SIMD2(x + hw * 0.15, s.bottom + c.len), z: z, depth: c.len, thick: c.len, alpha: -s.fade))
                }
            }
        }
        // The berm riding in front of the plow blade.
        let plow = world.plow
        if plow.isVisible, plow.berm > 1 {
            let shape = plow.bermShape
            let steps = 14
            let start = plow.bladeX - plow.facing * 2
            var prev: (x: Float, h: Float)?
            for k in 0...steps {
                let t = Float(k) / Float(steps)
                // Tall against the blade, tapering forward.
                let h = shape.height * (1 - t * t) * (0.85 + 0.15 * sin(t * 9 + world.time * 3))
                let x = start + plow.facing * t * shape.length
                if let p = prev { quad(p.x, p.h, x, h, base: plow.groundY, z: 0.001, alpha: 1) }
                prev = (x, h)
            }
        }
        let count = pileScratch.count
        guard count > 0 else { return (nil, 0) }
        let buf = ensure(&pileBufs[slot], bytes: count * MemoryLayout<PileVertex>.stride)
        pileScratch.withUnsafeBytes { raw in buf.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count) }
        return (buf, count)
    }

    private func appendSurface(_ s: Surface, screen: Rect) {
        let n = s.cellCount
        let z = max(s.z - 0.002, 0)
        let h = s.heights
        let i0 = max(s.cellIndex(screen.minX) - 1, 0), i1 = min(s.cellIndex(screen.maxX) + 1, n - 1)
        guard i0 <= i1 else { return }
        // Boundary heights: average of neighbouring columns for a smooth crest.
        @inline(__always) func hb(_ j: Int) -> Float {
            if j <= 0 { return h[0] }
            if j >= n { return h[n - 1] }
            return (h[j - 1] + h[j]) * 0.5
        }
        for i in i0...i1 {
            let ha = hb(i), hc = hb(i + 1)
            guard ha > 0.04 || hc > 0.04 else { continue }
            let xa = s.minX + Float(i) * s.cellW
            let xc = min(xa + s.cellW, s.maxX)
            quad(xa, ha, xc, hc, baseA: s.baseY(atX: xa), baseC: s.baseY(atX: xc), z: z, alpha: s.fade)
        }
    }

    @inline(__always) private func quad(_ xa: Float, _ ha: Float, _ xc: Float, _ hc: Float, base: Float, z: Float, alpha: Float) {
        quad(xa, ha, xc, hc, baseA: base, baseC: base, z: z, alpha: alpha)
    }

    @inline(__always) private func quad(_ xa: Float, _ ha: Float, _ xc: Float, _ hc: Float,
                                        baseA: Float, baseC: Float, z: Float, alpha: Float) {
        // Base sits half a point into the ledge so no hairline gap shows.
        let ta = PileVertex(pos: SIMD2(xa, baseA - ha), z: z, depth: 0, thick: ha, alpha: alpha)
        let tc = PileVertex(pos: SIMD2(xc, baseC - hc), z: z, depth: 0, thick: hc, alpha: alpha)
        let ba = PileVertex(pos: SIMD2(xa, baseA + 0.5), z: z, depth: ha + 0.5, thick: ha, alpha: alpha)
        let bc = PileVertex(pos: SIMD2(xc, baseC + 0.5), z: z, depth: hc + 0.5, thick: hc, alpha: alpha)
        pileScratch.append(ta); pileScratch.append(tc); pileScratch.append(ba)
        pileScratch.append(tc); pileScratch.append(bc); pileScratch.append(ba)
    }

    private var occScratch: [OccVertex] = []

    private func fillOccluders(world: World, screen: Rect) -> (MTLBuffer?, Int) {
        occScratch.removeAll(keepingCapacity: true)
        for o in world.occluders {
            let r = o.rect
            guard r.maxX > screen.minX, r.minX < screen.maxX, r.maxY > screen.minY, r.minY < screen.maxY else { continue }
            let a = OccVertex(pos: SIMD2(r.minX, r.minY), z: o.z), b = OccVertex(pos: SIMD2(r.maxX, r.minY), z: o.z)
            let c = OccVertex(pos: SIMD2(r.minX, r.maxY), z: o.z), d = OccVertex(pos: SIMD2(r.maxX, r.maxY), z: o.z)
            occScratch.append(contentsOf: [a, b, c, b, d, c])
        }
        for r in world.exemptRects {
            guard r.maxX > screen.minX, r.minX < screen.maxX, r.maxY > screen.minY, r.minY < screen.maxY else { continue }
            let z: Float = 0.002
            let a = OccVertex(pos: SIMD2(r.minX, r.minY), z: z), b = OccVertex(pos: SIMD2(r.maxX, r.minY), z: z)
            let c = OccVertex(pos: SIMD2(r.minX, r.maxY), z: z), d = OccVertex(pos: SIMD2(r.maxX, r.maxY), z: z)
            occScratch.append(contentsOf: [a, b, c, b, d, c])
        }
        let count = occScratch.count
        guard count > 0 else { return (nil, 0) }
        let buf = ensure(&occBufs[slot], bytes: count * MemoryLayout<OccVertex>.stride)
        occScratch.withUnsafeBytes { raw in buf.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count) }
        return (buf, count)
    }

    private var snowmanDraws: [(index: Int, stage: Int)] = []

    /// Snowmen go after the truck's 6 quads (index 6+), one quad each.
    private func fillSnowmen(world: World, screen: Rect, into out: UnsafeMutablePointer<TruckQuad>) {
        snowmanDraws.removeAll(keepingCapacity: true)
        var n = 6
        for m in world.snowmen where m.screenIndex < world.screens.count && n < 16 {
            let sc = world.screens[m.screenIndex].frame
            guard sc.minX == screen.minX, sc.minY == screen.minY else { continue }
            let ground = world.surfaces.first { $0.kind == .ground && $0.contains(x: m.x) && $0.top == sc.maxY }
            let baseY = (ground?.surfaceY(atX: m.x) ?? sc.maxY) + 5
            let h = m.height, w = h * SnowmanTextures.aspect
            let stage = min(max(Int(m.stage.rounded(.up)), 1), 4)
            out[n] = TruckQuad(center: SIMD2(m.x, baseY - h / 2), half: SIMD2(w / 2, h / 2), angle: 0, flip: 1,
                               alpha: m.alpha, kind: 0)
            snowmanDraws.append((n, stage - 1))
            n += 1
        }
    }

    /// Order in the buffer: shadow, body, blade, rear wheel, front wheel, beacon glow; snowmen after.
    private func fillTruck(world: World, screen: Rect, into buf: MTLBuffer) -> Int {
        let p = world.plow
        let outAll = buf.contents().bindMemory(to: TruckQuad.self, capacity: 16)
        fillSnowmen(world: world, screen: screen, into: outAll)
        guard p.isVisible else { return snowmanDraws.isEmpty ? 0 : 6 }
        let f = p.frame
        guard f.maxX > screen.minX - 20, f.minX < screen.maxX + 20, f.maxY > screen.minY, f.minY < screen.maxY + 10 else {
            return snowmanDraws.isEmpty ? 0 : 6
        }
        truckOnScreen = true
        let L = p.length, H = p.height
        let flip = p.facing
        let out = buf.contents().bindMemory(to: TruckQuad.self, capacity: 16)
        // Positions are authored for a right-facing truck; mirror for left.
        func X(_ fx: Float) -> Float { flip > 0 ? f.minX + fx * L : f.maxX - fx * L }
        let layout = TruckTextures.layout
        let bob = sin(world.time * 22) * min(abs(p.vx) / 700, 1) * 0.6
        var n = 0
        out[n] = TruckQuad(center: SIMD2(X(0.5), p.groundY - 1), half: SIMD2(L * 0.56, 5), angle: 0, flip: 1, alpha: 1, kind: 2); n += 1
        let body = layout.body
        out[n] = TruckQuad(center: SIMD2(X(body.cx), f.minY + body.cy * H + bob), half: SIMD2(body.w * L / 2, body.h * H / 2),
                           angle: 0, flip: flip, alpha: 1, kind: 0); n += 1
        let bl = layout.blade
        let lift = (1 - p.blade) * H * 0.07
        out[n] = TruckQuad(center: SIMD2(X(bl.cx), f.minY + bl.cy * H - lift), half: SIMD2(bl.w * L / 2, bl.h * H / 2),
                           angle: 0, flip: flip, alpha: 1, kind: 3); n += 1
        let r = layout.wheelRadius * H
        let spin = p.wheelAngle * (flip > 0 ? 1 : 1)
        for wx in layout.wheelX {
            out[n] = TruckQuad(center: SIMD2(X(wx), p.groundY - r), half: SIMD2(r, r), angle: spin, flip: 1, alpha: 1, kind: 4); n += 1
        }
        let bc = layout.beacon
        out[n] = TruckQuad(center: SIMD2(X(bc.x), f.minY + bc.y * H + bob), half: SIMD2(H * 0.34, H * 0.34),
                           angle: 0, flip: 1, alpha: 1, kind: 1); n += 1
        return n
    }

    private var truckOnScreen = false

    private func drawTruck(enc: MTLRenderCommandEncoder, u: inout Uniforms, count: Int, buf: MTLBuffer, pileBuf: MTLBuffer?) {
        let ub = MemoryLayout<Uniforms>.stride
        let stride = MemoryLayout<TruckQuad>.stride
        enc.setRenderPipelineState(shared.truckPipe)
        enc.setDepthStencilState(shared.depthOff)
        enc.setVertexBytes(&u, length: ub, index: 1)
        enc.setFragmentBytes(&u, length: ub, index: 1)
        let t = shared.truck
        // shadow (kind 2, texture unused)
        for d in snowmanDraws {
            enc.setVertexBuffer(buf, offset: d.index * stride, index: 0)
            enc.setFragmentTexture(shared.snowman.stages[d.stage], index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
        }
        guard truckOnScreen else { return }
        truckOnScreen = false
        let draws: [(Int, Int, MTLTexture)] = [(0, 1, t.body), (1, 1, t.body), (2, 1, t.blade), (3, 2, t.wheel), (5, 1, t.body)]
        for (first, n, tex) in draws where first + n <= count {
            enc.setVertexBuffer(buf, offset: first * stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
        }
    }
}
