import AppKit
import Metal
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import SnowsillCore

/// Renders the README images offscreen: the real simulation and the real Metal
/// renderer, composited over a staged, generic Mac desktop. Nothing on the
/// user's own screen is captured. Run with SNOWSILL_SNAPSHOTS=<folder>.
enum Snapshots {
    static let size = CGSize(width: 1600, height: 1000)
    static let scale: CGFloat = 2

    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["SNOWSILL_SNAPSHOTS"] else { return false }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let shared = MetalShared() else { print("no Metal"); return true }
        let r = OverlayRenderer(shared: shared, layer: CAMetalLayer())
        let stage = Stage()

        // 1. Hero: snow piled on windows, the Dock, the ground; icicles and a snowman.
        let hero = makeWorld(stage)
        hero.params.intensity = 0.75
        settle(hero, seconds: 70)
        save(compose(stage, world: hero, renderer: r, shared: shared), out.appendingPathComponent("hero.png"))

        // 2. The pointer pushing snow off a window.
        let push = hero
        var px: Float = 120, frames = 0
        while frames < 24 {
            push.setPointer(x: px, y: 168, dt: 1.0 / 60)
            push.step(dt: 1.0 / 60)
            px += 9; frames += 1
        }
        save(compose(stage, world: push, renderer: r, shared: shared, pointer: CGPoint(x: CGFloat(px), y: 168)),
             out.appendingPathComponent("pointer.png"))

        // 3. The plow mid-clear, plus a GIF of the whole run.
        let plow = makeWorld(stage)
        plow.params.intensity = 0.55
        settle(plow, seconds: 70)
        plow.plow.spawn(screenIndex: 0, world: plow, auto: true)
        var gifFrames: [CGImage] = []
        var t: Float = 0
        var saved = false
        while plow.plow.isVisible && t < 20 {
            plow.step(dt: 1.0 / 60); t += 1.0 / 60
            autoreleasepool {
                if Int((t * 60).rounded()) % 4 == 0 {
                    let img = compose(stage, world: plow, renderer: r, shared: shared)
                    gifFrames.append(downscale(img, width: 800))
                }
                if !saved, plow.plow.state == .plowing, plow.plow.bladeX > 980 {
                    save(compose(stage, world: plow, renderer: r, shared: shared), out.appendingPathComponent("plow.png"))
                    saved = true
                }
            }
        }
        writeGIF(gifFrames, delay: 0.05, to: out.appendingPathComponent("plow.gif"))

        // 4. Rain and fog.
        let rain = makeWorld(stage)
        rain.params.precipitation = .rain
        rain.params.intensity = 0.8
        rain.params.fog = 0.55
        rain.params.wind = -0.25
        settle(rain, seconds: 4)
        save(compose(stage, world: rain, renderer: r, shared: shared), out.appendingPathComponent("rain.png"))

        // 5. Menu tabs, welcome window, DMG window.
        let model = AppModel()
        for tab in ["Sky", "Snow", "Plow", "More"] {
            setenv("SNOWSILL_TAB", tab, 1)
            if let img = renderView(SettingsView(model: model).background(Color(nsColor: .windowBackgroundColor)),
                                    width: 340) {
                save(img, out.appendingPathComponent("menu-\(tab.lowercased()).png"))
            }
        }
        if let img = renderNSView(WelcomeWindow.makeView(model: model), size: CGSize(width: 560, height: 490)) {
            save(img, out.appendingPathComponent("welcome.png"))
        }
        save(dmgWindow(), out.appendingPathComponent("installer.png"))
        print("snapshots written to \(out.path)")
        return true
    }

    // MARK: World

    static func makeWorld(_ s: Stage) -> World {
        let w = World()
        w.setScreens([ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, w: Float(size.width), h: Float(size.height)),
                                 dock: s.dockLedge, menuBar: Float(s.menuBar))])
        w.params.pile = 0.8
        w.params.melt = 0
        w.params.pileBoost = 3
        w.setWindows(s.windows.map { WindowInfo(id: $0.id, frame: Rect($0.rect)) }, offscreenAlive: [])
        return w
    }

    static func settle(_ w: World, seconds: Float) {
        var t: Float = 0
        while t < seconds { w.step(dt: 1.0 / 60); t += 1.0 / 60 }
    }

    // MARK: Compositing

    static func compose(_ stage: Stage, world: World, renderer: OverlayRenderer, shared: MetalShared,
                        pointer: CGPoint? = nil) -> CGImage {
        let pw = Int(size.width * scale), ph = Int(size.height * scale)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pw, height: ph, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let tex = shared.device.makeTexture(descriptor: d)!
        renderer.render(world: world, screen: Rect(x: 0, y: 0, w: Float(size.width), h: Float(size.height)),
                        scale: Float(scale), offscreen: tex)
        var bytes = [UInt8](repeating: 0, count: pw * ph * 4)
        tex.getBytes(&bytes, bytesPerRow: pw * 4, from: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0)
        let overlay = CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pw * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                              provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true,
                              intent: .defaultIntent)!
        let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(stage.background, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.draw(overlay, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        if let p = pointer { drawCursor(ctx, at: p) }
        return ctx.makeImage()!
    }

    static func drawCursor(_ ctx: CGContext, at p: CGPoint) {
        ctx.saveGState()
        ctx.translateBy(x: p.x * scale, y: (size.height - p.y) * scale)
        ctx.scaleBy(x: scale * 1.3, y: -scale * 1.3)
        let path = CGMutablePath()
        path.move(to: .zero); path.addLine(to: CGPoint(x: 0, y: 17)); path.addLine(to: CGPoint(x: 4.5, y: 13))
        path.addLine(to: CGPoint(x: 7.5, y: 19.5)); path.addLine(to: CGPoint(x: 10, y: 18.3)); path.addLine(to: CGPoint(x: 7, y: 12))
        path.addLine(to: CGPoint(x: 12.5, y: 12)); path.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.5))
        ctx.addPath(path); ctx.setFillColor(.black); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path); ctx.setStrokeColor(.white); ctx.setLineWidth(1.2); ctx.strokePath()
        ctx.restoreGState()
    }

    static func save(_ img: CGImage, _ url: URL) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func downscale(_ img: CGImage, width: Int) -> CGImage {
        let h = Int(CGFloat(img.height) * CGFloat(width) / CGFloat(img.width))
        let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: h))
        return ctx.makeImage()!
    }

    static func writeGIF(_ frames: [CGImage], delay: Double, to url: URL) {
        guard !frames.isEmpty,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for f in frames {
            CGImageDestinationAddImage(dest, f, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
    }

    // MARK: Views

    static func renderView<V: View>(_ view: V, width: CGFloat) -> CGImage? {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.appearance = NSAppearance(named: .darkAqua)
        let fit = host.fittingSize
        return renderNSView(host, size: CGSize(width: width, height: fit.height))
    }

    static func renderNSView(_ view: NSView, size: CGSize) -> CGImage? {
        let win = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = .windowBackgroundColor
        view.frame = NSRect(origin: .zero, size: size)
        win.contentView = view
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    static func dmgWindow() -> CGImage {
        let W: CGFloat = 660, H: CGFloat = 448, title: CGFloat = 28, s: CGFloat = 2
        let ctx = CGContext(data: nil, width: Int(W * s), height: Int(H * s), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: s, y: s)
        let win = CGPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.addPath(win); ctx.clip()
        ctx.setFillColor(CGColor(gray: 0.16, alpha: 1)); ctx.fill(CGRect(x: 0, y: H - title, width: W, height: title))
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            ctx.setFillColor(c.cgColor); ctx.fillEllipse(in: CGRect(x: 12 + CGFloat(i) * 20, y: H - 20, width: 12, height: 12))
        }
        let titleStr = NSAttributedString(string: "Snowsill", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                                           .foregroundColor: NSColor(white: 0.85, alpha: 1)])
        let tl = CTLineCreateWithAttributedString(titleStr)
        ctx.textPosition = CGPoint(x: W / 2 - 28, y: H - 19); CTLineDraw(tl, ctx)
        if let bg = NSImage(contentsOfFile: "build/dmg/background@2x.png")?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(bg, in: CGRect(x: 0, y: 0, width: W, height: H - title))
        }
        func icon(_ img: NSImage, center: CGPoint, label: String) {
            let r = CGRect(x: center.x - 56, y: (H - title) - center.y - 56, width: 112, height: 112)
            var want = CGRect(x: 0, y: 0, width: 224, height: 224)
            if let cg = img.cgImage(forProposedRect: &want, context: nil, hints: nil) { ctx.interpolationQuality = .high; ctx.draw(cg, in: r) }
            let str = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                                     .foregroundColor: NSColor.white])
            let line = CTLineCreateWithAttributedString(str)
            let w = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.textPosition = CGPoint(x: center.x - CGFloat(w) / 2, y: r.minY - 18); CTLineDraw(line, ctx)
        }
        if let appIcon = NSImage(contentsOfFile: "docs/icon-1024.png") { icon(appIcon, center: CGPoint(x: 180, y: 200), label: "Snowsill") }
        icon(NSWorkspace.shared.icon(forFile: "/Applications"), center: CGPoint(x: 480, y: 200), label: "Applications")
        return ctx.makeImage()!
    }
}

/// A generic, staged Mac desktop: wallpaper, three dark windows, Dock, menu bar.
/// Original artwork; nothing from the user's own Mac.
final class Stage {
    struct Win { let id: Int; let rect: CGRect; let kind: Int; let title: String }
    let menuBar: CGFloat = 26
    let windows: [Win] = [   // front → back, global points (y down)
        Win(id: 3, rect: CGRect(x: 660, y: 560, width: 420, height: 230), kind: 2, title: "Music"),
        Win(id: 1, rect: CGRect(x: 150, y: 190, width: 560, height: 400), kind: 0, title: "Winter notes"),
        Win(id: 2, rect: CGRect(x: 840, y: 140, width: 600, height: 400), kind: 1, title: "Photos"),
    ]
    let dock = CGRect(x: 430, y: 926, width: 740, height: 68)
    var dockLedge: Rect { Rect(x: Float(dock.minX), y: Float(dock.minY), w: Float(dock.width), h: Float(Snapshots.size.height - dock.minY)) }
    private(set) var background: CGImage!

    init() { background = draw() }

    private func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor { TruckTextures.c(hex, a) }

    private func draw() -> CGImage {
        let W = Snapshots.size.width, H = Snapshots.size.height, s = Snapshots.scale
        let ctx = CGContext(data: nil, width: Int(W * s), height: Int(H * s), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)   // y down
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func grad(_ cols: [CGColor]) -> CGGradient { CGGradient(colorsSpace: space, colors: cols as CFArray, locations: nil)! }
        // Wallpaper: twilight sky over soft snowy hills.
        ctx.drawLinearGradient(grad([c(0x12_0E_34), c(0x2E_23_7A), c(0x6A_4F_D8), c(0xC9_9C_E8)]),
                               start: .zero, end: CGPoint(x: 0, y: H), options: [])
        ctx.drawRadialGradient(grad([c(0xFF_E9_F4, 0.9), c(0xFF_E9_F4, 0)]), startCenter: CGPoint(x: 1240, y: 220), startRadius: 0,
                               endCenter: CGPoint(x: 1240, y: 220), endRadius: 90, options: [])
        ctx.setFillColor(c(0xFF_F6_FA)); ctx.fillEllipse(in: CGRect(x: 1214, y: 194, width: 52, height: 52))
        for (i, col) in [c(0x3A_2C_86), c(0x2A_1F_66), c(0x1C_15_4A)].enumerated() {
            let y0 = 640 + CGFloat(i) * 90
            let hill = CGMutablePath()
            hill.move(to: CGPoint(x: 0, y: H)); hill.addLine(to: CGPoint(x: 0, y: y0))
            hill.addCurve(to: CGPoint(x: W, y: y0 - 30 + CGFloat(i) * 20), control1: CGPoint(x: W * 0.3, y: y0 - 140),
                          control2: CGPoint(x: W * 0.65, y: y0 + 80))
            hill.addLine(to: CGPoint(x: W, y: H)); hill.closeSubpath()
            ctx.addPath(hill); ctx.setFillColor(col); ctx.fillPath()
        }
        // Windows, back to front.
        for w in windows.reversed() { drawWindow(ctx, w) }
        // Dock
        let dockPath = CGPath(roundedRect: dock, cornerWidth: 20, cornerHeight: 20, transform: nil)
        ctx.addPath(dockPath); ctx.setFillColor(c(0x2A_26_40, 0.72)); ctx.fillPath()
        ctx.addPath(dockPath); ctx.setStrokeColor(c(0xFF_FF_FF, 0.18)); ctx.setLineWidth(1); ctx.strokePath()
        let symbols = ["folder.fill", "safari.fill", "message.fill", "music.note", "photo.fill", "calendar", "note.text",
                       "paintbrush.pointed.fill", "terminal.fill", "gearshape.fill"]
        let tints: [UInt32] = [0x3D_8B_FF, 0x2F_A8_F5, 0x34_C7_59, 0xFF_3B_5C, 0xFF_9F_0A, 0xFF_45_3A, 0xFF_CC_00, 0xAF_52_DE, 0x30_30_38, 0x8E_8E_93]
        for (i, sym) in symbols.enumerated() {
            let r = CGRect(x: dock.minX + 14 + CGFloat(i) * 72, y: dock.minY + 8, width: 52, height: 52)
            let p = CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)
            ctx.saveGState(); ctx.addPath(p); ctx.clip()
            ctx.drawLinearGradient(grad([c(tints[i]), c(tints[i], 0.75)]), start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
            ctx.restoreGState()
            glyph(ctx, sym, in: r.insetBy(dx: 13, dy: 13))
        }
        // Menu bar
        ctx.setFillColor(c(0x16_12_30, 0.55)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: menuBar))
        text(ctx, "Snowsill", x: 18, y: 18, size: 13, weight: .bold)
        text(ctx, "File    Edit    View    Window    Help", x: 92, y: 18, size: 13, weight: .regular)
        text(ctx, "Mon 9:41", x: W - 80, y: 18, size: 13, weight: .medium)
        glyph(ctx, "snowflake", in: CGRect(x: W - 114, y: 5, width: 16, height: 16))
        glyph(ctx, "wifi", in: CGRect(x: W - 146, y: 6, width: 18, height: 14))
        return ctx.makeImage()!
    }

    private func drawWindow(_ ctx: CGContext, _ w: Win) {
        let r = w.rect
        let p = CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: c(0x05_03_18, 0.55))
        ctx.addPath(p); ctx.setFillColor(c(0x1F_1D_26)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(p); ctx.clip()
        ctx.setFillColor(c(0x2A_28_33)); ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 38))
        for (i, col) in [c(0xFF_5F_57), c(0xFE_BC_2E), c(0x28_C8_40)].enumerated() {
            ctx.setFillColor(col); ctx.fillEllipse(in: CGRect(x: r.minX + 14 + CGFloat(i) * 20, y: r.minY + 13, width: 12, height: 12))
        }
        text(ctx, w.title, x: r.midX - CGFloat(w.title.count) * 3.6, y: r.minY + 24, size: 13, weight: .semibold, alpha: 0.85)
        let body = CGRect(x: r.minX, y: r.minY + 38, width: r.width, height: r.height - 38)
        switch w.kind {
        case 0:
            text(ctx, "A cosy weekend list", x: body.minX + 28, y: body.minY + 44, size: 22, weight: .bold)
            for (i, line) in ["☕︎  Hot chocolate with marshmallows", "🧣  Find the lilac scarf", "⛄︎  Build a snowman (or let Snowsill do it)",
                              "🎬  Movie night by the window", "📚  Finish the winter book"].enumerated() {
                text(ctx, line, x: body.minX + 28, y: body.minY + 92 + CGFloat(i) * 38, size: 15, weight: .regular, alpha: 0.85)
            }
        case 1:
            let cols: [[UInt32]] = [[0x6A_4F_D8, 0xFF_6F_A8], [0x2F_A8_F5, 0x5C_F2_C8], [0xFF_9F_0A, 0xFF_45_3A],
                                    [0x34_C7_59, 0x2F_A8_F5], [0xAF_52_DE, 0x3D_8B_FF], [0xFF_CC_00, 0xFF_6F_A8]]
            for i in 0..<6 {
                let col = i % 3, row = i / 3
                let tile = CGRect(x: body.minX + 20 + CGFloat(col) * 188, y: body.minY + 20 + CGFloat(row) * 168, width: 176, height: 156)
                let tp = CGPath(roundedRect: tile, cornerWidth: 10, cornerHeight: 10, transform: nil)
                ctx.saveGState(); ctx.addPath(tp); ctx.clip()
                ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c(cols[i][0]), c(cols[i][1])] as CFArray, locations: nil)!,
                                       start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
                ctx.restoreGState()
            }
        default:
            let art = CGRect(x: body.minX + 22, y: body.minY + 22, width: 140, height: 140)
            let ap = CGPath(roundedRect: art, cornerWidth: 12, cornerHeight: 12, transform: nil)
            ctx.saveGState(); ctx.addPath(ap); ctx.clip()
            ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c(0xFF_6F_A8), c(0x6A_4F_D8)] as CFArray, locations: nil)!,
                                   start: CGPoint(x: art.minX, y: art.minY), end: CGPoint(x: art.maxX, y: art.maxY), options: [])
            ctx.restoreGState()
            glyph(ctx, "snowflake", in: art.insetBy(dx: 44, dy: 44))
            text(ctx, "First Snow", x: art.maxX + 22, y: art.minY + 40, size: 20, weight: .bold)
            text(ctx, "Lo-fi winter mix", x: art.maxX + 22, y: art.minY + 66, size: 14, weight: .regular, alpha: 0.7)
            ctx.setFillColor(c(0xFF_FF_FF, 0.18)); ctx.fill(CGRect(x: art.maxX + 22, y: art.minY + 110, width: 210, height: 4))
            ctx.setFillColor(c(0xFF_FF_FF, 0.9)); ctx.fill(CGRect(x: art.maxX + 22, y: art.minY + 110, width: 92, height: 4))
        }
        ctx.restoreGState()
        ctx.addPath(p); ctx.setStrokeColor(c(0xFF_FF_FF, 0.12)); ctx.setLineWidth(1); ctx.strokePath()
    }

    private func text(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1) {
        let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                             .foregroundColor: NSColor(white: 1, alpha: alpha)])
        let line = CTLineCreateWithAttributedString(str)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: x, y: y); ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func glyph(_ ctx: CGContext, _ name: String, in r: CGRect) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: r.height * 2, weight: .semibold)) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect); NSColor.white.set(); rect.fill(using: .sourceAtop); return true
        }
        guard let cg = tinted.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
        let aspect = img.size.width / max(img.size.height, 1)
        let w = min(r.width, r.height * aspect), h = w / aspect
        ctx.draw(cg, in: CGRect(x: (r.width - w) / 2, y: (r.height - h) / 2, width: w, height: h))
        ctx.restoreGState()
    }
}
