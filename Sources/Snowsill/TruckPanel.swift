import AppKit
import SnowsillCore

/// An invisible panel that sits exactly over the truck so it can be grabbed,
/// swiped and clicked, while the rest of the overlay stays click-through.
final class TruckPanel {
    let panel: NSPanel
    private let view: TruckHitView
    private var lastFrame: NSRect = .zero

    init(model: AppModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        view = TruckHitView(model: model)
        panel.contentView = view
    }

    /// The panel exists only while the truck is parked (or being dragged,
    /// when the grab keeps the mouse even though the panel stays put). Moving a
    /// window every frame stalls WindowServer, so it never follows motion.
    func sync(plow: Plow, visible: Bool) {
        let interactive = visible && (plow.state == .parked || plow.state == .dragging)
        guard interactive else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        guard plow.state == .parked else { return }
        let r = Coords.appKit(plow.frame).insetBy(dx: 2, dy: 0)
        if r != lastFrame {
            panel.setFrame(r, display: false)
            lastFrame = r
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

final class TruckHitView: NSView {
    private weak var model: AppModel?
    private var scrollAccum: CGFloat = 0
    private var scrollStart: CFTimeInterval = 0

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.push()
        model?.plowGrab(x: Float(NSEvent.mouseLocation.x))
    }

    override func mouseDragged(with event: NSEvent) {
        model?.plowDrag(x: Float(NSEvent.mouseLocation.x))
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        model?.plowRelease()
    }

    /// Two-finger trackpad swipe over the truck sends it plowing that way.
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
        if event.phase == .began { scrollAccum = 0; scrollStart = CACurrentMediaTime() }
        // Natural scrolling inverts deltas; normalise to finger direction.
        let finger = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        scrollAccum += finger
        if abs(scrollAccum) > 40 || event.phase == .ended {
            if abs(scrollAccum) > 12 {
                model?.plowSwipe(direction: scrollAccum > 0 ? 1 : -1, speed: 650)
            }
            scrollAccum = 0
        }
    }
}
