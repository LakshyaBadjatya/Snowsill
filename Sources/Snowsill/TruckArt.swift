import AppKit
import CoreGraphics
import Metal
import MetalKit

/// The snow plow, drawn once with Core Graphics into Metal textures.
/// Original artwork: a municipal plow truck with a curved yellow blade, an
/// orange cab and sander body, and an amber roof beacon.
/// Authored on a 900 × 432 canvas for the whole truck box, y down, facing right.
final class TruckTextures {
    struct Part { let cx: Float, cy: Float, w: Float, h: Float }
    struct Layout {
        let body = Part(cx: 0.45, cy: 0.5, w: 0.90, h: 1.0)
        let blade = Part(cx: 0.925, cy: 0.74, w: 0.15, h: 0.52)
        let wheelRadius: Float = 0.17
        let wheelX: [Float] = [0.22, 0.66]
        let beacon = (x: Float(0.70), y: Float(0.13))
    }
    static let layout = Layout()

    let body: MTLTexture
    let blade: MTLTexture
    let wheel: MTLTexture

    private static let W: CGFloat = 900, H: CGFloat = 432
    /// Texture pixels per canvas unit (1.0 → 900 px wide truck texture).
    private static let res: CGFloat = 1.0

    init(device: MTLDevice) {
        let loader = MTKTextureLoader(device: device)
        func tex(_ w: CGFloat, _ h: CGFloat, _ draw: (CGContext) -> Void) -> MTLTexture {
            let img = TruckTextures.image(width: w, height: h, draw: draw)
            return try! loader.newTexture(cgImage: img, options: [
                .SRGB: false, .generateMipmaps: true, .allocateMipmaps: true,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
            ])
        }
        let L = TruckTextures.layout
        body = tex(TruckTextures.W * CGFloat(L.body.w), TruckTextures.H * CGFloat(L.body.h), TruckTextures.drawBody)
        blade = tex(TruckTextures.W * CGFloat(L.blade.w), TruckTextures.H * CGFloat(L.blade.h), TruckTextures.drawBlade)
        let d = TruckTextures.H * CGFloat(L.wheelRadius) * 2
        wheel = tex(d, d, TruckTextures.drawWheel)
    }

    static func image(width: CGFloat, height: CGFloat, draw: (CGContext) -> Void) -> CGImage {
        let pw = Int((width * res).rounded()), ph = Int((height * res).rounded())
        let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: res, y: -res)           // y down, canvas units
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        draw(ctx)
        return ctx.makeImage()!
    }

    /// The whole truck in one image (menu and welcome screen).
    static func preview() -> NSImage {
        let img = image(width: W, height: H) { ctx in
            let L = layout
            drawBody(ctx)
            ctx.saveGState()
            ctx.translateBy(x: W * CGFloat(L.blade.cx - L.blade.w / 2), y: H * CGFloat(L.blade.cy - L.blade.h / 2))
            drawBlade(ctx)
            ctx.restoreGState()
            let r = H * CGFloat(L.wheelRadius)
            for wx in L.wheelX {
                ctx.saveGState()
                ctx.translateBy(x: W * CGFloat(wx) - r, y: H - 2 * r)
                drawWheel(ctx)
                ctx.restoreGState()
            }
            // Beacon glow
            ctx.setFillColor(c(0xFF_A0_20, 0.35))
            ctx.fillEllipse(in: CGRect(x: 631 - 30, y: 52 - 30, width: 60, height: 60))
        }
        return NSImage(cgImage: img, size: NSSize(width: W / 3, height: H / 3))
    }

    // MARK: Palette

    static func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    static let orange = c(0xF2_7A_1A), orangeLight = c(0xFF_9E_45), orangeDark = c(0xC4_57_0B)
    static let steel = c(0x2A_2E_35), steelLight = c(0x4A_50_5A)
    static let glassTop = c(0x8F_B4_D0), glassBottom = c(0x2C_45_5E)
    static let yellow = c(0xFF_C5_2E), yellowDark = c(0xD8_93_00)
    static let snow = c(0xFA_FC_FF), snowShade = c(0xD3_DE_EE)

    static func gradient(_ ctx: CGContext, _ path: CGPath, _ c0: CGColor, _ c1: CGColor, from: CGPoint, to: CGPoint) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c0, c1] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    static func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    // MARK: Body (x 0…810 of the 900 canvas)

    static func drawBody(_ ctx: CGContext) {
        let wheelY: CGFloat = 432 - 73.4
        let wheels: [CGFloat] = [198, 594]

        // Chassis rail
        ctx.addPath(rounded(CGRect(x: 30, y: 292, width: 770, height: 40), 8))
        ctx.setFillColor(steel); ctx.fillPath()

        // Exhaust stack
        gradient(ctx, rounded(CGRect(x: 470, y: 30, width: 14, height: 270), 5), c(0xE4_E8_EE), c(0x8A_92_9D),
                 from: CGPoint(x: 470, y: 0), to: CGPoint(x: 484, y: 0))
        ctx.addPath(rounded(CGRect(x: 466, y: 24, width: 22, height: 10), 3)); ctx.setFillColor(c(0x3A_3F_47)); ctx.fillPath()

        // Sander / dump body
        let dump = rounded(CGRect(x: 24, y: 118, width: 438, height: 184), 10)
        gradient(ctx, dump, orangeLight, orangeDark, from: CGPoint(x: 0, y: 118), to: CGPoint(x: 0, y: 302))
        // Ribs
        ctx.setStrokeColor(c(0xB0_4C_08, 0.75)); ctx.setLineWidth(5)
        for x in stride(from: 80.0, through: 420.0, by: 68.0) {
            ctx.move(to: CGPoint(x: x, y: 132)); ctx.addLine(to: CGPoint(x: x, y: 288))
        }
        ctx.strokePath()
        // Top rail
        ctx.addPath(rounded(CGRect(x: 18, y: 112, width: 450, height: 14), 6)); ctx.setFillColor(orangeDark); ctx.fillPath()
        // Reflective stripe
        let stripe = CGRect(x: 30, y: 232, width: 426, height: 16)
        ctx.saveGState(); ctx.addRect(stripe); ctx.clip()
        for i in 0..<20 {
            let x = 30 + CGFloat(i) * 44
            ctx.setFillColor(i % 2 == 0 ? c(0xF5_F5_F5) : c(0xD6_2B_2B))
            ctx.move(to: CGPoint(x: x, y: 248)); ctx.addLine(to: CGPoint(x: x + 22, y: 232))
            ctx.addLine(to: CGPoint(x: x + 44, y: 232)); ctx.addLine(to: CGPoint(x: x + 22, y: 248)); ctx.fillPath()
        }
        ctx.restoreGState()
        // Snow cap on the body
        let cap = CGMutablePath()
        cap.move(to: CGPoint(x: 20, y: 116))
        var x: CGFloat = 20
        var k = 0
        while x < 466 {
            let bump: CGFloat = [10, 14, 8, 16, 11, 13][k % 6]
            cap.addQuadCurve(to: CGPoint(x: x + 30, y: 112), control: CGPoint(x: x + 15, y: 112 - bump))
            x += 30; k += 1
        }
        cap.addLine(to: CGPoint(x: 466, y: 124)); cap.addLine(to: CGPoint(x: 20, y: 124)); cap.closeSubpath()
        gradient(ctx, cap, snow, snowShade, from: CGPoint(x: 0, y: 96), to: CGPoint(x: 0, y: 124))
        // Rear spreader
        ctx.addPath(rounded(CGRect(x: 4, y: 246, width: 30, height: 54), 6)); ctx.setFillColor(steelLight); ctx.fillPath()
        ctx.addPath(rounded(CGRect(x: 8, y: 160, width: 12, height: 26), 3)); ctx.setFillColor(c(0xE0_2A_2A)); ctx.fillPath()

        // Cab
        let cab = CGMutablePath()
        cab.move(to: CGPoint(x: 494, y: 300))
        cab.addLine(to: CGPoint(x: 494, y: 84))
        cab.addQuadCurve(to: CGPoint(x: 512, y: 66), control: CGPoint(x: 494, y: 66))
        cab.addLine(to: CGPoint(x: 676, y: 66))
        cab.addQuadCurve(to: CGPoint(x: 692, y: 76), control: CGPoint(x: 686, y: 66))
        cab.addLine(to: CGPoint(x: 732, y: 164))
        cab.addLine(to: CGPoint(x: 786, y: 172))
        cab.addQuadCurve(to: CGPoint(x: 806, y: 194), control: CGPoint(x: 806, y: 174))
        cab.addLine(to: CGPoint(x: 806, y: 300))
        cab.closeSubpath()
        gradient(ctx, cab, orangeLight, orangeDark, from: CGPoint(x: 0, y: 66), to: CGPoint(x: 0, y: 300))
        ctx.addPath(cab); ctx.setStrokeColor(c(0x9E_45_06, 0.6)); ctx.setLineWidth(2.5); ctx.strokePath()

        // Windows
        let win = CGMutablePath()
        win.move(to: CGPoint(x: 516, y: 88))
        win.addLine(to: CGPoint(x: 668, y: 88))
        win.addLine(to: CGPoint(x: 708, y: 160))
        win.addLine(to: CGPoint(x: 516, y: 160))
        win.closeSubpath()
        gradient(ctx, win, glassTop, glassBottom, from: CGPoint(x: 0, y: 88), to: CGPoint(x: 0, y: 160))
        ctx.saveGState(); ctx.addPath(win); ctx.clip()
        ctx.setFillColor(c(0xFF_FF_FF, 0.22))
        ctx.move(to: CGPoint(x: 560, y: 88)); ctx.addLine(to: CGPoint(x: 600, y: 88))
        ctx.addLine(to: CGPoint(x: 560, y: 160)); ctx.addLine(to: CGPoint(x: 520, y: 160)); ctx.fillPath()
        ctx.restoreGState()
        // Pillar between door window and windshield
        ctx.setFillColor(orange); ctx.fill(CGRect(x: 600, y: 88, width: 8, height: 72))
        // Door seam + handle
        ctx.setStrokeColor(c(0xA8_4A_07, 0.8)); ctx.setLineWidth(3)
        ctx.move(to: CGPoint(x: 510, y: 172)); ctx.addLine(to: CGPoint(x: 510, y: 290))
        ctx.move(to: CGPoint(x: 646, y: 172)); ctx.addLine(to: CGPoint(x: 646, y: 290)); ctx.strokePath()
        ctx.addPath(rounded(CGRect(x: 618, y: 182, width: 20, height: 7), 3)); ctx.setFillColor(steel); ctx.fillPath()
        // Mirror
        ctx.addPath(rounded(CGRect(x: 716, y: 104, width: 10, height: 40), 3)); ctx.setFillColor(steel); ctx.fillPath()
        // Grille, headlight, bumper
        ctx.addPath(rounded(CGRect(x: 772, y: 206, width: 34, height: 60), 4)); ctx.setFillColor(c(0x30_34_3B)); ctx.fillPath()
        ctx.setStrokeColor(c(0x55_5B_66)); ctx.setLineWidth(2)
        for y in stride(from: 214.0, through: 258.0, by: 8.0) { ctx.move(to: CGPoint(x: 776, y: y)); ctx.addLine(to: CGPoint(x: 803, y: y)) }
        ctx.strokePath()
        ctx.addPath(rounded(CGRect(x: 784, y: 180, width: 22, height: 18), 6)); ctx.setFillColor(c(0xFF_F4_C8)); ctx.fillPath()
        ctx.addPath(rounded(CGRect(x: 740, y: 284, width: 70, height: 22), 6)); ctx.setFillColor(steelLight); ctx.fillPath()
        // Blade mount arm
        ctx.addPath(rounded(CGRect(x: 760, y: 300, width: 50, height: 16), 4)); ctx.setFillColor(steel); ctx.fillPath()

        // Roof beacon (glow is drawn live by the shader)
        ctx.addPath(rounded(CGRect(x: 606, y: 58, width: 50, height: 10), 3)); ctx.setFillColor(steel); ctx.fillPath()
        let dome = CGMutablePath()
        dome.addArc(center: CGPoint(x: 631, y: 58), radius: 18, startAngle: .pi, endAngle: 0, clockwise: false)
        dome.closeSubpath()
        gradient(ctx, dome, c(0xFF_D0_6A), c(0xF0_8A_00), from: CGPoint(x: 0, y: 40), to: CGPoint(x: 0, y: 58))

        // Wheel wells (wheels are separate sprites drawn on top)
        for wx in wheels {
            ctx.addArc(center: CGPoint(x: wx, y: wheelY), radius: 86, startAngle: .pi, endAngle: 0, clockwise: false)
            ctx.closePath()
            ctx.setFillColor(c(0x16_18_1C)); ctx.fillPath()
            // Fender lip
            ctx.addArc(center: CGPoint(x: wx, y: wheelY), radius: 88, startAngle: .pi * 1.05, endAngle: -0.05 * .pi, clockwise: false)
            ctx.setStrokeColor(c(0x22_25_2B)); ctx.setLineWidth(7); ctx.strokePath()
        }
    }

    // MARK: Blade (135 × 225 canvas units)

    static func drawBlade(_ ctx: CGContext) {
        let w: CGFloat = 135, h: CGFloat = 224.6
        // Push frame behind the moldboard
        ctx.addPath(rounded(CGRect(x: 0, y: 120, width: 44, height: 22), 5)); ctx.setFillColor(steel); ctx.fillPath()
        ctx.addPath(rounded(CGRect(x: 0, y: 168, width: 40, height: 18), 5)); ctx.setFillColor(steel); ctx.fillPath()
        // Curved moldboard
        let board = CGMutablePath()
        board.move(to: CGPoint(x: 30, y: 8))
        board.addLine(to: CGPoint(x: 70, y: 2))
        board.addQuadCurve(to: CGPoint(x: w - 4, y: h - 8), control: CGPoint(x: 140, y: 70))
        board.addLine(to: CGPoint(x: 40, y: h - 8))
        board.addQuadCurve(to: CGPoint(x: 30, y: 8), control: CGPoint(x: 60, y: 110))
        board.closeSubpath()
        gradient(ctx, board, yellow, yellowDark, from: CGPoint(x: 40, y: 0), to: CGPoint(x: 130, y: h))
        // Concave shading on the face
        let shade = CGMutablePath()
        shade.move(to: CGPoint(x: 70, y: 2))
        shade.addQuadCurve(to: CGPoint(x: w - 4, y: h - 8), control: CGPoint(x: 140, y: 70))
        shade.addLine(to: CGPoint(x: w - 22, y: h - 8))
        shade.addQuadCurve(to: CGPoint(x: 66, y: 8), control: CGPoint(x: 120, y: 80))
        shade.closeSubpath()
        ctx.addPath(shade); ctx.setFillColor(c(0xFF_E2_8A, 0.55)); ctx.fillPath()
        ctx.addPath(board); ctx.setStrokeColor(c(0x9C_6A_00)); ctx.setLineWidth(3); ctx.strokePath()
        // Hazard stripes along the top
        ctx.saveGState(); ctx.addPath(board); ctx.clip()
        for i in 0..<8 {
            ctx.setFillColor(i % 2 == 0 ? c(0x1E_1E_1E) : c(0xFF_D6_4A))
            let x0 = 20 + CGFloat(i) * 18
            ctx.move(to: CGPoint(x: x0, y: 30)); ctx.addLine(to: CGPoint(x: x0 + 18, y: 0))
            ctx.addLine(to: CGPoint(x: x0 + 36, y: 0)); ctx.addLine(to: CGPoint(x: x0 + 18, y: 30)); ctx.fillPath()
        }
        ctx.restoreGState()
        // Steel cutting edge
        ctx.addPath(rounded(CGRect(x: 38, y: h - 12, width: w - 40, height: 12), 3)); ctx.setFillColor(c(0x5A_60_6B)); ctx.fillPath()
        // Marker post with a flag
        ctx.setStrokeColor(c(0x22_22_22)); ctx.setLineWidth(3)
        ctx.move(to: CGPoint(x: 120, y: 120)); ctx.addLine(to: CGPoint(x: 120, y: 6)); ctx.strokePath()
        ctx.setFillColor(c(0xFF_4A_1C))
        ctx.move(to: CGPoint(x: 120, y: 6)); ctx.addLine(to: CGPoint(x: 98, y: 14)); ctx.addLine(to: CGPoint(x: 120, y: 22)); ctx.fillPath()
    }

    // MARK: Wheel (146.9 square)

    static func drawWheel(_ ctx: CGContext) {
        let d: CGFloat = 146.88, r = d / 2
        let ctr = CGPoint(x: r, y: r)
        // Tire
        let tire = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: d - 2, height: d - 2), transform: nil)
        ctx.addPath(tire); ctx.setFillColor(c(0x1A_1B_1E)); ctx.fillPath()
        // Tread blocks around the rim
        ctx.setFillColor(c(0x34_36_3B))
        for i in 0..<18 {
            let a = CGFloat(i) / 18 * 2 * .pi
            ctx.saveGState()
            ctx.translateBy(x: ctr.x, y: ctr.y); ctx.rotate(by: a)
            ctx.addPath(rounded(CGRect(x: r - 12, y: -5, width: 10, height: 10), 2)); ctx.fillPath()
            ctx.restoreGState()
        }
        // Sidewall
        ctx.addEllipse(in: CGRect(x: ctr.x - r * 0.72, y: ctr.y - r * 0.72, width: r * 1.44, height: r * 1.44))
        ctx.setFillColor(c(0x26_28_2D)); ctx.fillPath()
        // Rim
        let rim = CGPath(ellipseIn: CGRect(x: ctr.x - r * 0.55, y: ctr.y - r * 0.55, width: r * 1.1, height: r * 1.1), transform: nil)
        gradient(ctx, rim, c(0xE6_EA_F0), c(0x8E_96_A2), from: CGPoint(x: 0, y: ctr.y - r * 0.55), to: CGPoint(x: 0, y: ctr.y + r * 0.55))
        // Lug nuts (show the rotation)
        ctx.setFillColor(c(0x50_56_60))
        for i in 0..<6 {
            let a = CGFloat(i) / 6 * 2 * .pi
            let p = CGPoint(x: ctr.x + cos(a) * r * 0.32, y: ctr.y + sin(a) * r * 0.32)
            ctx.addEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
        }
        ctx.fillPath()
        ctx.addEllipse(in: CGRect(x: ctr.x - 12, y: ctr.y - 12, width: 24, height: 24))
        ctx.setFillColor(c(0x3C_42_4B)); ctx.fillPath()
        // One orange spoke mark so spinning reads clearly.
        ctx.setFillColor(c(0xF2_7A_1A))
        ctx.addPath(rounded(CGRect(x: ctr.x + r * 0.38, y: ctr.y - 3, width: r * 0.14, height: 6), 2)); ctx.fillPath()
    }
}
