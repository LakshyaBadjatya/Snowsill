import AppKit
import ApplicationServices
import SnowsillCore

/// Finder's desktop icons, read through Accessibility (only with the user's
/// permission: "Precise Dock and desktop icons"). Each icon's image becomes a
/// tiny ledge snow can settle on.
enum DesktopIcons {
    static func read() -> [WindowInfo] {
        guard AXIsProcessTrusted(),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return [] }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        var out: [WindowInfo] = []
        func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }
        func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
        func frame(_ e: AXUIElement) -> CGRect? {
            guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
            var pt = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &pt)
            AXValueGetValue(s as! AXValue, .cgSize, &sz)
            return CGRect(origin: pt, size: sz)
        }
        // The desktop is Finder's AXScrollArea; icons are AXImage items inside it.
        for top in children(app) where (attr(top, kAXRoleAttribute) as? String) == "AXScrollArea" {
            var stack = children(top)
            var guardCount = 0
            while let e = stack.popLast(), guardCount < 2000 {
                guardCount += 1
                let role = attr(e, kAXRoleAttribute) as? String
                if role == "AXImage", let f = frame(e), f.width >= 24, f.width <= 300 {
                    let title = (attr(e, kAXTitleAttribute) as? String) ?? "\(f.minX),\(f.minY)"
                    // Icon art sits in the square top part of the item.
                    let side = min(f.width, f.height)
                    let r = Rect(x: Float(f.midX - side * 0.4), y: Float(f.minY + side * 0.12), w: Float(side * 0.8), h: Float(side * 0.75))
                    out.append(WindowInfo(id: 3_000_000_000 + abs(title.hashValue % 1_000_000_000), frame: r, desktop: true, cornerRadius: 6))
                } else {
                    stack.append(contentsOf: children(e))
                }
            }
        }
        return out
    }
}
