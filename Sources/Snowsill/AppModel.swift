import AppKit
import Combine
import ServiceManagement
import SnowsillCore

/// Owns the simulation and wires it to screens, windows, settings and power.
final class AppModel: ObservableObject {
    let world = World()
    let perf = PerfLog()
    let prefs = Preferences()
    let weather = WeatherService()
    private let tracker = WindowTracker()
    private var shared: MetalShared!
    private var overlays: [Int: OverlayController] = [:]
    private var truckPanel: TruckPanel!
    private var bag = Set<AnyCancellable>()
    private var lastStep: CFTimeInterval = 0
    private var fullscreenScreens = Set<Int>()
    private var locked = false
    private var asleep = false
    private var onBattery = false
    private var slowTimer: Timer?
    private var lastDock: [Int: Rect?] = [:]
    private var lastExempt = Set<String>()
    private var lastIcons = false
    let sound = SoundEngine()
    let updater = Updater()
    private var hotKey: HotKey?
    private var scheduleBlocked = false
    private var lastPlowState: Plow.State = .hidden

    @Published private(set) var plowVisible = false
    @Published private(set) var running = true
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    func start() {
        guard let s = MetalShared() else {
            let a = NSAlert()
            a.messageText = "Snowsill needs Metal"
            a.informativeText = "This Mac's graphics could not be set up."
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        shared = s
        updater.start()
        if let boost = ProcessInfo.processInfo.environment["SNOWSILL_PILEBOOST"].flatMap(Float.init) {
            world.params.pileBoost = boost
        }
        truckPanel = TruckPanel(model: self)
        perf.extra = { [weak self] in
            guard let w = self?.world else { return "" }
            return "particles=\(w.particles.count) windows=\(w.surfaces.filter { $0.kind == .window }.count) dock=\(w.surfaces.contains { $0.kind == .dock }) plow=\(w.plow.state)"
        }
        rebuildScreens()

        tracker.onUpdate = { [weak self] snap in
            guard let self else { return }
            self.world.setWindows(snap.windows, offscreenAlive: snap.offscreenAlive, silent: snap.silent)
            if snap.fullscreenScreens != self.fullscreenScreens {
                self.fullscreenScreens = snap.fullscreenScreens
                self.updateRunState()
            }
        }
        tracker.start(hz: 30)

        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildScreens()
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tracker.markSilent()
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.prefs.flush()
            self?.asleep = true; self?.updateRunState()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false; self?.updateRunState()
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.refreshDock() }
            }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true; self?.updateRunState()
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false; self?.updateRunState()
        }
        dnc.addObserver(forName: .init("com.apple.dock.prefchanged"), object: nil, queue: .main) { [weak self] _ in
            self?.refreshDock()
        }

        prefs.objectWillChange
            .merge(with: weather.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyPrefs() }
            .store(in: &bag)

        // Slow housekeeping: battery, Dock size (icons come and go).
        slowTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let b = PowerMonitor.onBattery
            if b != self.onBattery { self.onBattery = b; self.updateRunState() }
            self.refreshDock()
            self.checkAutoPlow()
            self.checkSchedule()
        }
        onBattery = PowerMonitor.onBattery
        if prefs.mode == .live, !prefs.city.isEmpty { weather.setCity(prefs.city) }
        applyPrefs()
        checkSchedule()
        updateRunState()
    }

    // MARK: Frame

    /// Steps the simulation once per display refresh (shared by all screens).
    func advance(now: CFTimeInterval) {
        let dt = now - lastStep
        guard dt > 0.002 else { return }
        lastStep = now
        let p = Coords.world(NSEvent.mouseLocation)
        let step = Float(min(dt, 0.05))
        world.setPointer(x: p.x, y: p.y, dt: step)
        world.step(dt: step)
        truckPanel.sync(plow: world.plow, visible: running)
        if plowVisible != world.plow.isVisible { plowVisible = world.plow.isVisible }
        let ps = world.plow.state
        if ps != lastPlowState {
            if ps == .plowing && lastPlowState != .waiting { sound.beep() }
            lastPlowState = ps
        }
        sound.update(wind: world.params.precipitation == .none ? abs(world.windNow) * 0.5 : 0.25 + abs(world.windNow) * 0.75,
                     truckSpeed: world.plow.isVisible ? abs(world.plow.vx) : 0)
    }

    // MARK: Screens

    private func rebuildScreens() {
        let screens = NSScreen.screens
        var infos: [ScreenInfo] = []
        var keep = Set<Int>()
        for s in screens {
            let id = s.displayID
            keep.insert(id)
            let dock = DockLocator.dockRect(on: s, exact: prefs.exactDock)
            lastDock[id] = dock
            let menuBar = Float(max(s.frame.maxY - s.visibleFrame.maxY, 0))
            infos.append(ScreenInfo(id: id, frame: Coords.world(s.frame), dock: dock, menuBar: menuBar))
            if let o = overlays[id] { o.update(screen: s) } else { overlays[id] = OverlayController(screen: s, shared: shared, model: self) }
        }
        for (id, o) in overlays where !keep.contains(id) { o.invalidate(); overlays[id] = nil }
        world.setScreens(infos)
        tracker.setScreens(infos.map { ($0.id, $0.frame) })
        tracker.invalidate()
        updateRunState()
    }

    private func refreshDock() {
        var changed = false
        for s in NSScreen.screens {
            let d = DockLocator.dockRect(on: s, exact: prefs.exactDock)
            if lastDock[s.displayID] != d { changed = true }
        }
        if changed { rebuildScreens() }
    }

    // MARK: Settings → simulation

    private func applyPrefs() {
        var p = world.params
        let live = prefs.mode == .live ? weather.current : nil
        if let w = live {
            p.precipitation = w.precipitation
            p.intensity = w.intensity * Float(0.4 + prefs.intensity * 1.2)
            p.wind = w.wind
            p.fog = w.fog
        } else {
            p.precipitation = prefs.precipitation
            p.intensity = Float(prefs.intensity)
            p.wind = Float(prefs.wind)
            p.fog = Float(prefs.fog)
        }
        p.flakeScale = Float(prefs.flakeSize)
        p.pile = Float(prefs.pile)
        p.melt = Float(prefs.melt)
        p.pointer = prefs.pointer
        if p.pileOnWindows != prefs.pileOnWindows && !prefs.pileOnWindows { dropSnow(kind: .window) }
        if p.pileOnDock != prefs.pileOnDock && !prefs.pileOnDock { dropSnow(kind: .dock) }
        p.pileOnWindows = prefs.pileOnWindows
        p.desktopOnly = prefs.desktopOnly
        let off = Set(prefs.disabledDisplays)
        p.disabledScreens = Set(NSScreen.screens.filter { off.contains($0.localizedName) }.map(\.displayID))
        p.icicles = prefs.icicles
        p.snowman = prefs.snowman
        p.frost = prefs.frost
        sound.enabled = prefs.sounds && running
        if prefs.hotkey && hotKey == nil {
            hotKey = HotKey { [weak self] in self?.prefs.enabled.toggle() }
        } else if !prefs.hotkey { hotKey = nil }
        let ex = Set(prefs.exemptApps)
        if ex != lastExempt { lastExempt = ex; tracker.setExempt(ex) }
        p.pileOnDock = prefs.pileOnDock
        p.pileOnDesktop = prefs.pileOnDesktop
        #if !APPSTORE
        let icons = prefs.exactDock && prefs.pileOnDesktop
        if icons != lastIcons { lastIcons = icons; tracker.setDesktopIcons(icons) }
        #endif
        world.params = p
        if prefs.exactDock && !AXIsProcessTrusted() { DockLocator.requestAccess() }
        updateRunState()
    }

    private func dropSnow(kind: Surface.Kind) {
        for s in world.surfaces where s.kind == kind { s.melt(1000) }
    }

    func updateRunState() {
        let run = prefs.enabled && !locked && !asleep && !(onBattery && prefs.pauseOnBattery) && !scheduleBlocked
        if running != run {
            running = run
            if !run && !prefs.enabled { world.clearAll(); world.plow.dismissNow() }
        }
        let offNames = Set(prefs.disabledDisplays)
        let offIDs = Set(NSScreen.screens.filter { offNames.contains($0.localizedName) }.map(\.displayID))
        for (id, o) in overlays {
            let blocked = (prefs.pauseFullscreen && fullscreenScreens.contains(id)) || offIDs.contains(id)
            if run && !blocked { o.show() } else { o.hide() }
        }
        if !run { truckPanel?.sync(plow: world.plow, visible: false) }
        sound.enabled = prefs.sounds && run
        lastStep = CACurrentMediaTime()
    }

    // MARK: Scene (menu tiles)

    var scene: Scene {
        let p = prefs.mode == .live ? (weather.current?.precipitation ?? prefs.precipitation) : prefs.precipitation
        let fog = prefs.mode == .live ? Double(weather.current?.fog ?? Float(prefs.fog)) : prefs.fog
        switch p {
        case .snow: return .snow
        case .rain: return .rain
        case .none: return fog > 0.05 ? .fog : .clear
        }
    }

    func setScene(_ s: Scene) {
        switch s {
        case .snow: prefs.precipitation = .snow
        case .rain: prefs.precipitation = .rain
        case .fog: prefs.precipitation = .none; prefs.fog = max(prefs.fog, 0.6)
        case .clear: prefs.precipitation = .none; prefs.fog = 0
        }
    }

    lazy var truckPreview: NSImage = TruckTextures.preview()

    // MARK: Schedule

    /// Why the schedule is holding the snow, for the status line.
    @Published private(set) var scheduleNote: String?

    private func checkSchedule() {
        let now = Date()
        let cal = Calendar.current
        var blocked = false
        switch prefs.schedule {
        case .always: break
        case .winter:
            // Dec–Feb in the north; Jun–Aug south of the equator (from the time zone).
            let month = cal.component(.month, from: now)
            let south = TimeZone.current.identifier.hasPrefix("Australia") || TimeZone.current.identifier.hasPrefix("Pacific/Auckland")
                || TimeZone.current.identifier.hasPrefix("America/Argentina") || TimeZone.current.identifier.hasPrefix("America/Santiago")
                || TimeZone.current.identifier.hasPrefix("Africa/Johannesburg")
            let winter = south ? [6, 7, 8] : [12, 1, 2]
            blocked = !winter.contains(month)
        case .evenings:
            let h = cal.component(.hour, from: now)
            blocked = !(h >= 18 || h < 7)
        }
        let note = blocked ? (prefs.schedule == .winter ? "Waiting for winter" : "Waiting for the evening") : nil
        if note != scheduleNote { scheduleNote = note }
        if blocked != scheduleBlocked { scheduleBlocked = blocked; updateRunState() }
    }

    // MARK: Auto plow

    private var lastAutoPlow: CFTimeInterval = 0

    /// When snow along the bottom of a screen gets deep, send the truck.
    private func checkAutoPlow() {
        guard prefs.autoPlow, running, !world.plow.isVisible,
              CACurrentMediaTime() - lastAutoPlow > 20 else { return }
        // Ground holds up to 1.8× the window cap; trigger between 15% and 85% of it.
        let groundCap = (4 + Float(prefs.pile) * 20) * 1.8
        let trigger = max(4, groundCap * (0.15 + Float(prefs.plowAt) * 0.7))
        for i in world.screens.indices where !world.params.disabledScreens.contains(world.screens[i].id)
            && world.bottomDepth(screenIndex: i) > trigger {
            world.plow.spawn(screenIndex: i, world: world, auto: true)
            lastAutoPlow = CACurrentMediaTime()
            return
        }
    }

    // MARK: Commands

    func clearSnow() { world.clearAll() }

    /// Depth (pt) at which the truck comes, for the settings label.
    var plowTriggerDepth: Int {
        let groundCap = (4 + prefs.pile * 20) * 1.8
        return Int(max(4, groundCap * (0.15 + prefs.plowAt * 0.7)).rounded())
    }

    func togglePlow() {
        if world.plow.isVisible { world.plow.dismiss(world: world); return }
        let mouse = NSEvent.mouseLocation
        let off = Set(prefs.disabledDisplays)
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) && !off.contains($0.localizedName) }
            ?? NSScreen.screens.first { !off.contains($0.localizedName) } ?? NSScreen.main
        let idx = world.screens.firstIndex { $0.id == screen?.displayID } ?? 0
        // One full job: drive in, clear the bottom, drive away.
        world.plow.spawn(screenIndex: idx, world: world, auto: true)
        plowVisible = true
    }

    func plowGrab(x: Float) { world.plow.beginDrag(pointerX: x, time: world.time) }
    func plowDrag(x: Float) { world.plow.drag(pointerX: x, time: world.time, world: world) }
    func plowRelease() { world.plow.endDrag(time: world.time, world: world) }
    func plowSwipe(direction: Float, speed: Float) { world.plow.swipe(direction: direction, speed: speed) }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Snowsill: login item: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
