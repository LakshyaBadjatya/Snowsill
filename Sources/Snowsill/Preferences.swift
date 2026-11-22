import Foundation
import Combine
import SnowsillCore

/// User settings, persisted in UserDefaults.
final class Preferences: ObservableObject {
    enum Mode: String, CaseIterable { case manual, live }
    enum Schedule: String, CaseIterable { case always, winter, evenings }

    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var mode: Mode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var precipitation: Precipitation { didSet { d.set(precipitation.rawValue, forKey: "precipitation") } }
    @Published var intensity: Double { didSet { d.set(intensity, forKey: "intensity") } }
    @Published var flakeSize: Double { didSet { d.set(flakeSize, forKey: "flakeSize") } }
    @Published var pile: Double { didSet { d.set(pile, forKey: "pile") } }
    @Published var melt: Double { didSet { d.set(melt, forKey: "melt") } }
    @Published var wind: Double { didSet { d.set(wind, forKey: "wind") } }
    @Published var fog: Double { didSet { d.set(fog, forKey: "fog") } }
    @Published var pointer: Bool { didSet { d.set(pointer, forKey: "pointer") } }
    @Published var pileOnWindows: Bool { didSet { d.set(pileOnWindows, forKey: "pileOnWindows") } }
    @Published var pileOnDock: Bool { didSet { d.set(pileOnDock, forKey: "pileOnDock") } }
    @Published var pauseFullscreen: Bool { didSet { d.set(pauseFullscreen, forKey: "pauseFullscreen") } }
    @Published var pauseOnBattery: Bool { didSet { d.set(pauseOnBattery, forKey: "pauseOnBattery") } }
    @Published var exactDock: Bool { didSet { d.set(exactDock, forKey: "exactDock") } }
    @Published var city: String { didSet { d.set(city, forKey: "city") } }
    @Published var autoPlow: Bool { didSet { d.set(autoPlow, forKey: "autoPlow") } }
    /// 0...1: how deep the bottom gets before the truck comes.
    @Published var plowAt: Double { didSet { d.set(plowAt, forKey: "plowAt") } }
    @Published var desktopOnly: Bool { didSet { d.set(desktopOnly, forKey: "desktopOnly") } }
    @Published var exemptApps: [String] { didSet { d.set(exemptApps, forKey: "exemptApps") } }
    @Published var icicles: Bool { didSet { d.set(icicles, forKey: "icicles") } }
    @Published var snowman: Bool { didSet { d.set(snowman, forKey: "snowman") } }
    @Published var frost: Bool { didSet { d.set(frost, forKey: "frost") } }
    @Published var sounds: Bool { didSet { d.set(sounds, forKey: "sounds") } }
    @Published var hotkey: Bool { didSet { d.set(hotkey, forKey: "hotkey") } }
    @Published var schedule: Schedule { didSet { d.set(schedule.rawValue, forKey: "schedule") } }
    @Published var welcomed: Bool { didSet { d.set(welcomed, forKey: "welcomed") } }
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }
    @Published var pileOnDesktop: Bool { didSet { d.set(pileOnDesktop, forKey: "pileOnDesktop") } }
    /// Displays switched off, by their name (stable across reconnects).
    @Published var disabledDisplays: [String] { didSet { d.set(disabledDisplays, forKey: "disabledDisplays") } }
    @Published var lastTab: String { didSet { d.set(lastTab, forKey: "lastTab") } }

    /// Writes everything to disk now (called on quit and sleep).
    func flush() { d.synchronize() }

    init() {
        d.register(defaults: [
            "enabled": true, "mode": Mode.manual.rawValue, "precipitation": Precipitation.snow.rawValue,
            "intensity": 0.5, "flakeSize": 1.0, "pile": 0.6, "melt": 0.25, "wind": 0.0, "fog": 0.0,
            "pointer": true, "pileOnWindows": true, "pileOnDock": true,
            "pauseFullscreen": true, "pauseOnBattery": false, "exactDock": false, "city": "", "autoPlow": true, "plowAt": 0.5, "desktopOnly": false, "exemptApps": [String](),
            "icicles": true, "snowman": true, "frost": true, "sounds": false, "hotkey": true,
            "schedule": Schedule.always.rawValue, "welcomed": false, "showInDock": true, "pileOnDesktop": true, "disabledDisplays": [String](), "lastTab": "Sky",
        ])
        enabled = d.bool(forKey: "enabled")
        mode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .manual
        precipitation = Precipitation(rawValue: d.string(forKey: "precipitation") ?? "") ?? .snow
        intensity = d.double(forKey: "intensity")
        flakeSize = d.double(forKey: "flakeSize")
        pile = d.double(forKey: "pile")
        melt = d.double(forKey: "melt")
        wind = d.double(forKey: "wind")
        fog = d.double(forKey: "fog")
        pointer = d.bool(forKey: "pointer")
        pileOnWindows = d.bool(forKey: "pileOnWindows")
        pileOnDock = d.bool(forKey: "pileOnDock")
        pauseFullscreen = d.bool(forKey: "pauseFullscreen")
        pauseOnBattery = d.bool(forKey: "pauseOnBattery")
        exactDock = d.bool(forKey: "exactDock")
        city = d.string(forKey: "city") ?? ""
        autoPlow = d.bool(forKey: "autoPlow")
        plowAt = d.double(forKey: "plowAt")
        desktopOnly = d.bool(forKey: "desktopOnly")
        exemptApps = d.stringArray(forKey: "exemptApps") ?? []
        icicles = d.bool(forKey: "icicles")
        snowman = d.bool(forKey: "snowman")
        frost = d.bool(forKey: "frost")
        sounds = d.bool(forKey: "sounds")
        hotkey = d.bool(forKey: "hotkey")
        schedule = Schedule(rawValue: d.string(forKey: "schedule") ?? "") ?? .always
        welcomed = d.bool(forKey: "welcomed")
        showInDock = d.bool(forKey: "showInDock")
        pileOnDesktop = d.bool(forKey: "pileOnDesktop")
        disabledDisplays = d.stringArray(forKey: "disabledDisplays") ?? []
        lastTab = d.string(forKey: "lastTab") ?? "Sky"
    }
}
