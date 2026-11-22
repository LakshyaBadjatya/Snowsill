import AppKit
import ApplicationServices
import SnowsillCore

/// Finds the Dock's platter. Without permission it is estimated from the
/// Dock's preferences and the running apps; with Accessibility (optional,
/// "Exact Dock edge") it is read from the Dock's icon list.
enum DockLocator {
    /// Dock rect in global points (y down) for the given screen, or nil.
    static func dockRect(on screen: NSScreen, exact: Bool) -> Rect? {
        let inset = screen.visibleFrame.minY - screen.frame.minY
        guard inset >= 20 else { return nil }    // hidden, or on a side
        let sf = Coords.world(screen.frame)
        if exact, AXIsProcessTrusted(), let r = axListFrame() {
            // The glass platter extends a little past the icons.
            let pad: Float = 8
            let top = min(r.minY - pad, sf.maxY - Float(inset))
            return Rect(x: r.minX - pad, y: top, w: r.w + pad * 2, h: sf.maxY - top)
        }
        let (items, seps) = itemCount()
        guard let e = DockGeometry.estimate(inset: Float(inset), items: items, separators: seps, screenWidth: sf.w) else { return nil }
        // The platter's top sits a few points below the visible frame's edge.
        let top = sf.maxY - Float(inset) + 4
        return Rect(x: sf.minX + e.x, y: top, w: e.width, h: sf.maxY - top)
    }

    static func itemCount() -> (Int, Int) {
        let domain = "com.apple.dock" as CFString
        var pinned = Set<String>(["com.apple.finder"])
        if let apps = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [[String: Any]] {
            for a in apps {
                if let td = a["tile-data"] as? [String: Any], let bid = td["bundle-identifier"] as? String { pinned.insert(bid) }
            }
        }
        var items = pinned.count
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let b = app.bundleIdentifier { if !pinned.contains(b) { items += 1 } } else { items += 1 }
        }
        var seps = 1
        var ok: DarwinBoolean = false
        let showRecents = CFPreferencesGetAppBooleanValue("show-recents" as CFString, domain, &ok)
        if !ok.boolValue || showRecents {
            let r = (CFPreferencesCopyAppValue("recent-apps" as CFString, domain) as? [Any])?.count ?? 0
            if r > 0 { items += r; seps += 1 }
        }
        items += ((CFPreferencesCopyAppValue("persistent-others" as CFString, domain) as? [Any])?.count ?? 0) + 1
        return (items, seps)
    }

    /// The Dock's icon list frame via Accessibility (top-left global coords).
    static func axListFrame() -> Rect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for el in list {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            guard (role as? String) == (kAXListRole as String) else { continue }
            var posV: CFTypeRef?, sizeV: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV) == .success,
                  AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV) == .success else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(posV as! AXValue, .cgPoint, &p)
            AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
            guard s.width > 20 else { continue }
            return Rect(x: Float(p.x), y: Float(p.y), w: Float(s.width), h: Float(s.height))
        }
        return nil
    }

    /// Shows the system prompt for Accessibility (only when the user asks).
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
