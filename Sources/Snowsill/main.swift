import ServiceManagement
import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()
    private let welcome = WelcomeWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockPolicy()
        buildMainMenu()
        model.start()
        model.prefs.$showInDock.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyDockPolicy() } }
            .store(in: &bag)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.action = #selector(togglePopover(_:))
            b.target = self
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon()
        model.prefs.objectWillChange.merge(with: model.weather.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateIcon() }
            .store(in: &bag)

        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: SettingsView(model: model))
        // Let the popover grow and shrink with its content (tabs, the app list).
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        if !model.prefs.welcomed || ProcessInfo.processInfo.environment["SNOWSILL_WELCOME"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.welcome.show(model: self.model) }
        }
        if ProcessInfo.processInfo.environment["SNOWSILL_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.togglePopover(nil) }
        }
        // Test hooks: SNOWSILL_PLOW=<sec to call truck>, SNOWSILL_PLOW_GO=<sec to swipe it right>.
        let env = ProcessInfo.processInfo.environment
        if let t = env["SNOWSILL_PLOW"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.model.togglePlow() }
        }
        if let t = env["SNOWSILL_PLOW_GO"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.model.plowSwipe(direction: 1, speed: 520) }
        }
    }

    /// Dock icon on (default) or menu-bar only.
    private func applyDockPolicy() {
        NSApp.setActivationPolicy(model.prefs.showInDock ? .regular : .accessory)
        if !model.prefs.showInDock {
            // Keep the settings popover in front after hiding the Dock icon.
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    /// Clicking the Dock icon opens the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover(nil) }
        return true
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let m = NSMenu(title: "Snowsill")
        m.addItem(withTitle: "About Snowsill", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        m.addItem(.separator())
        let s = m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        s.target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Hide Snowsill", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        m.addItem(withTitle: "Quit Snowsill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        NSApp.mainMenu = main
    }

    @objc private func openSettings() { if !popover.isShown { togglePopover(nil) } }

    func applicationWillTerminate(_ notification: Notification) { model.prefs.flush() }

    private func updateIcon() {
        let p = model.prefs
        let name: String
        switch model.scene {
        case .snow: name = "snowflake"
        case .rain: name = "cloud.rain"
        case .fog: name = "cloud.fog"
        case .clear: name = "moon.stars"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Snowsill")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.appearsDisabled = !p.enabled
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let b = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
if Snapshots.runIfRequested() { exit(0) }
if ProcessInfo.processInfo.environment["SNOWSILL_REMOVE_LOGIN_ITEM"] == "1" {
    try? SMAppService.mainApp.unregister()
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
