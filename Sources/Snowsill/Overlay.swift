import AppKit
import QuartzCore
import SnowsillCore

/// A transparent, click-through window covering one screen, above apps and
/// the Dock, drawing with Metal.
final class OverlayController {
    let screenID: Int
    private(set) var screenRect: Rect
    private(set) var scale: Float
    let window: NSWindow
    private let metalView: NSView
    let renderer: OverlayRenderer
    private var link: CADisplayLink?
    private weak var model: AppModel?
    private var lastDraw: CFTimeInterval = 0
    private var drewEmpty = false
    var isShown = false

    init(screen: NSScreen, shared: MetalShared, model: AppModel) {
        self.model = model
        screenID = screen.displayID
        screenRect = Coords.world(screen.frame)
        scale = Float(screen.backingScaleFactor)
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar               // above the Dock and the menu bar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.sharingType = .readOnly

        metalView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        metalView.wantsLayer = true
        let layer = CAMetalLayer()
        layer.contentsScale = screen.backingScaleFactor
        layer.frame = metalView.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        metalView.layer?.addSublayer(layer)
        window.contentView = metalView
        window.setFrame(screen.frame, display: false)
        renderer = OverlayRenderer(shared: shared, layer: layer)
    }

    func update(screen: NSScreen) {
        screenRect = Coords.world(screen.frame)
        scale = Float(screen.backingScaleFactor)
        window.setFrame(screen.frame, display: false)
        (metalView.layer?.sublayers?.first as? CAMetalLayer)?.contentsScale = screen.backingScaleFactor
    }

    func show() {
        guard !isShown else { return }
        isShown = true
        drewEmpty = false
        window.orderFrontRegardless()
        if link == nil {
            let l = metalView.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        link?.isPaused = true
        window.orderOut(nil)
    }

    func invalidate() {
        link?.invalidate()
        link = nil
        window.orderOut(nil)
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard let model else { return }
        let now = CACurrentMediaTime()
        let t0 = now
        model.advance(now: now)
        defer { model.perf.frame(tick: now, work: CACurrentMediaTime() - t0) }
        let world = model.world
        // Nothing moving: redraw a few times a second (melting is slow) and
        // stop presenting entirely once the screen is empty, so WindowServer
        // has nothing new to composite.
        if world.isSettled {
            if !world.hasAnySnow && !world.plow.isVisible {
                if drewEmpty { return }
                drewEmpty = true
            } else if now - lastDraw < 0.25 {
                return
            }
        } else {
            drewEmpty = false
        }
        lastDraw = now
        renderer.render(world: world, screen: screenRect, scale: scale)
    }
}
