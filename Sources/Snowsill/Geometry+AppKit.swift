import AppKit
import SnowsillCore

/// Converts between AppKit screen space (origin bottom-left of the primary
/// display, y up) and the simulation's global space (origin top-left, y down,
/// same as CGWindowList bounds).
enum Coords {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func world(_ r: NSRect) -> Rect {
        Rect(x: Float(r.minX), y: Float(primaryHeight - r.maxY), w: Float(r.width), h: Float(r.height))
    }

    static func appKit(_ r: Rect) -> NSRect {
        NSRect(x: CGFloat(r.x), y: primaryHeight - CGFloat(r.y + r.h), width: CGFloat(r.w), height: CGFloat(r.h))
    }

    static func world(_ p: NSPoint) -> (x: Float, y: Float) {
        (Float(p.x), Float(primaryHeight - p.y))
    }
}

extension NSScreen {
    var displayID: Int {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }
}

extension Rect {
    init(_ r: CGRect) { self.init(x: Float(r.minX), y: Float(r.minY), w: Float(r.width), h: Float(r.height)) }
}
