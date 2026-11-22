import CoreGraphics
import Metal
import MetalKit

/// A snowman drawn with Core Graphics in four build stages:
/// base ball → body → head with face → beanie, scarf and stick arms.
/// Canvas 120 × 180 units, y down, feet at the bottom.
final class SnowmanTextures {
    static let aspect: Float = 120.0 / 180.0
    let stages: [MTLTexture]

    init(device: MTLDevice) {
        let loader = MTKTextureLoader(device: device)
        stages = (1...4).map { stage in
            let img = TruckTextures.image(width: 120, height: 180) { SnowmanTextures.draw($0, stage: stage) }
            return try! loader.newTexture(cgImage: img, options: [
                .SRGB: false, .generateMipmaps: true, .allocateMipmaps: true,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
            ])
        }
    }

    private static func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor { TruckTextures.c(hex, a) }

    private static func ball(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let path = CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2), transform: nil)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [c(0xFF_FF_FF), c(0xE6_EE_FA), c(0xB9_C8_E2)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx - r * 0.35, y: cy - r * 0.4), startRadius: 0,
                               endCenter: CGPoint(x: cx, y: cy), endRadius: r * 1.05, options: [])
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(c(0xA8_B8_D4, 0.6)); ctx.setLineWidth(1.2); ctx.strokePath()
    }

    static func draw(_ ctx: CGContext, stage: Int) {
        // Soft contact shadow
        ctx.setFillColor(c(0x8C_9C_BA, 0.35))
        ctx.fillEllipse(in: CGRect(x: 16, y: 170, width: 88, height: 10))

        if stage >= 4 {
            // Stick arms behind the body
            ctx.setStrokeColor(c(0x5A_3A_22)); ctx.setLineWidth(3.2); ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: 38, y: 100)); ctx.addLine(to: CGPoint(x: 6, y: 78))
            ctx.move(to: CGPoint(x: 14, y: 84)); ctx.addLine(to: CGPoint(x: 6, y: 70))
            ctx.move(to: CGPoint(x: 82, y: 100)); ctx.addLine(to: CGPoint(x: 114, y: 84))
            ctx.move(to: CGPoint(x: 104, y: 89)); ctx.addLine(to: CGPoint(x: 112, y: 74))
            ctx.strokePath()
        }
        ball(ctx, cx: 60, cy: 142, r: 36)
        guard stage >= 2 else { return }
        ball(ctx, cx: 60, cy: 94, r: 27)
        // Coal buttons
        ctx.setFillColor(c(0x2B_2D_33))
        for y in [84.0, 98.0, 112.0] { ctx.fillEllipse(in: CGRect(x: 57, y: y, width: 6, height: 6)) }
        guard stage >= 3 else { return }
        ball(ctx, cx: 60, cy: 54, r: 20)
        // Eyes, smile, carrot
        ctx.setFillColor(c(0x22_24_2A))
        ctx.fillEllipse(in: CGRect(x: 50, y: 45, width: 5.5, height: 5.5))
        ctx.fillEllipse(in: CGRect(x: 64, y: 45, width: 5.5, height: 5.5))
        for (i, x) in [50.0, 55.0, 60.0, 65.0, 70.0].enumerated() {
            let y = 62.0 + (i == 0 || i == 4 ? 0 : (i == 2 ? 3 : 2))
            ctx.fillEllipse(in: CGRect(x: x - 1.6, y: y, width: 3.2, height: 3.2))
        }
        ctx.setFillColor(c(0xFF_7A_1A))
        ctx.move(to: CGPoint(x: 60, y: 52)); ctx.addLine(to: CGPoint(x: 84, y: 57)); ctx.addLine(to: CGPoint(x: 60, y: 59))
        ctx.closePath(); ctx.fillPath()
        guard stage >= 4 else { return }
        // Scarf: coral-pink knit with a hanging tail
        ctx.setFillColor(c(0xFF_4F_7B))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 38, y: 70, width: 44, height: 11), cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: CGRect(x: 66, y: 74, width: 11, height: 28), cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(c(0xFF_C2_D4)); ctx.setLineWidth(2)
        for x in stride(from: 44.0, through: 76.0, by: 8.0) { ctx.move(to: CGPoint(x: x, y: 71)); ctx.addLine(to: CGPoint(x: x, y: 80)) }
        ctx.move(to: CGPoint(x: 66, y: 92)); ctx.addLine(to: CGPoint(x: 77, y: 92))
        ctx.strokePath()
        // Beanie: lilac with a pom-pom
        ctx.setFillColor(c(0x8B_6C_FF))
        let hat = CGMutablePath()
        hat.move(to: CGPoint(x: 40, y: 44))
        hat.addQuadCurve(to: CGPoint(x: 80, y: 44), control: CGPoint(x: 60, y: 10))
        hat.closeSubpath()
        ctx.addPath(hat); ctx.fillPath()
        ctx.setFillColor(c(0x6A_4D_E8))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 38, y: 38, width: 44, height: 9), cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(c(0xF4_F0_FF))
        ctx.fillEllipse(in: CGRect(x: 53, y: 12, width: 14, height: 14))
    }
}
