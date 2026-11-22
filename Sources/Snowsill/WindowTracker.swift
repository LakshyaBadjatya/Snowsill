import AppKit
import CoreGraphics
import SnowsillCore

/// Polls the on-screen window list on a background queue. Reads only window
/// bounds, ids and layers: no Screen Recording or Accessibility permission.
final class WindowTracker {
    struct Snapshot {
        var windows: [WindowInfo]
        var offscreenAlive: Set<Int>
        var silent: Bool
        var fullscreenScreens: Set<Int>
    }

    /// Called on the main thread when anything changed.
    var onUpdate: ((Snapshot) -> Void)?

    private let queue = DispatchQueue(label: "snowsill.windows", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let me = getpid()
    private var lastWindows: [WindowInfo] = []
    private var lastAlive: Set<Int> = []
    private var lastFull: Set<Int> = []
    private var trackedOffscreen: Set<Int> = []
    private let lock = NSLock()
    private var _screens: [(id: Int, rect: Rect)] = []
    private var _silentNext = false
    private var _exempt = Set<String>()
    private var bundleCache: [Int32: String] = [:]
    private var _desktopIcons = false
    private var iconCache: [WindowInfo] = []
    private var lastIconPoll: CFTimeInterval = 0

    /// Read desktop icon positions via Accessibility (only when the user turned on the precise option).
    func setDesktopIcons(_ on: Bool) { lock.lock(); _desktopIcons = on; lock.unlock(); invalidate() }

    func setExempt(_ ids: Set<String>) { lock.lock(); _exempt = ids; lock.unlock(); invalidate() }

    func setScreens(_ s: [(id: Int, rect: Rect)]) { lock.lock(); _screens = s; lock.unlock() }

    /// The next update is a Space switch or similar: no tumbling.
    func markSilent() { lock.lock(); _silentNext = true; lock.unlock() }

    func start(hz: Double = 30) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / hz, leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    /// Forces the next poll to report even if nothing changed.
    func invalidate() { queue.async { self.lastWindows = [WindowInfo(id: -1, frame: Rect(x: 0, y: 0, w: 0, h: 0))] } }

    private func poll() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        lock.lock(); let screens = _screens; var silent = _silentNext; _silentNext = false; let exemptIDs = _exempt
        let wantIcons = _desktopIcons; lock.unlock()

        var windows: [WindowInfo] = []
        windows.reserveCapacity(32)
        var full = Set<Int>()
        for w in list {
            let pid = (w[kCGWindowOwnerPID as String] as? Int32) ?? 0
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  pid != me,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd),
                  r.width >= 60, r.height >= 40 else { continue }
            let rect = Rect(r)
            // Full-screen: a window exactly covering a display.
            for s in screens where abs(rect.x - s.rect.x) < 1 && abs(rect.y - s.rect.y) < 1
                && abs(rect.w - s.rect.w) < 1 && abs(rect.h - s.rect.h) < 1 {
                full.insert(s.id)
            }
            var exempt = false
            if !exemptIDs.isEmpty {
                let bid: String
                if let c = bundleCache[pid] { bid = c } else {
                    bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                    bundleCache[pid] = bid
                }
                exempt = exemptIDs.contains(bid)
            }
            windows.append(WindowInfo(id: id, frame: rect, exempt: exempt))
        }

        // Desktop widgets (macOS 14+ desktop widgets are Notification Center windows at desktop level).
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer < -1_000_000,
                  (w[kCGWindowOwnerName as String] as? String) == "Notification Center",
                  let id = w[kCGWindowNumber as String] as? Int,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd),
                  r.width >= 80, r.width <= 1200, r.height >= 80 else { continue }
            windows.append(WindowInfo(id: id, frame: Rect(r), desktop: true, cornerRadius: 22))
        }
        // Desktop icons (Accessibility), refreshed every 2 s.
        if wantIcons {
            let now = CACurrentMediaTime()
            if now - lastIconPoll > 2 { lastIconPoll = now; iconCache = DesktopIcons.read() }
            windows.append(contentsOf: iconCache)
        } else {
            iconCache = []
        }

        // Windows that vanished: closed, or just minimized / on another Space?
        let currentIDs = Set(windows.map(\.id))
        let vanished = Set(lastWindows.map(\.id)).subtracting(currentIDs).union(trackedOffscreen).subtracting(currentIDs)
        var alive = Set<Int>()
        if !vanished.isEmpty {
            alive = existing(Array(vanished))
            // Many windows vanishing at once is a Space switch or app hide.
            if Set(lastWindows.map(\.id)).subtracting(currentIDs).count >= 3 { silent = true }
        }
        trackedOffscreen = alive

        guard windows != lastWindows || alive != lastAlive || full != lastFull || silent else { return }
        lastWindows = windows
        lastAlive = alive
        lastFull = full
        let snap = Snapshot(windows: windows, offscreenAlive: alive, silent: silent, fullscreenScreens: full)
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snap) }
    }

    /// Which of these window ids still exist anywhere (on or off screen).
    private func existing(_ ids: [Int]) -> Set<Int> {
        let ptrs = ids.filter { $0 > 0 }.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard !ptrs.isEmpty else { return [] }
        var values = ptrs
        guard let arr = CFArrayCreate(nil, &values, values.count, nil),
              let desc = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] else { return [] }
        var out = Set<Int>()
        for d in desc { if let id = d[kCGWindowNumber as String] as? Int { out.insert(id) } }
        return out
    }
}
