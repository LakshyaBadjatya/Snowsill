import SwiftUI
import AppKit
import SnowsillCore

// MARK: - Palette: "twilight snow"

enum Vibe {
    static let night = Color(red: 0x1E / 255, green: 0x1A / 255, blue: 0x46 / 255)
    static let lilac = Color(red: 0x8B / 255, green: 0x6C / 255, blue: 0xFF / 255)
    static let ice = Color(red: 0xCF / 255, green: 0xE6 / 255, blue: 0xFF / 255)
    static let coral = Color(red: 0xFF / 255, green: 0x4F / 255, blue: 0x7B / 255)
    static let snow = Color(red: 0xF6 / 255, green: 0xF8 / 255, blue: 0xFF / 255)
    static let glow = LinearGradient(colors: [lilac, Color(red: 0.42, green: 0.62, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }
}

enum Scene: String, CaseIterable, Identifiable {
    case snow, rain, fog, clear
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .snow: return "snowflake"
        case .rain: return "cloud.rain.fill"
        case .fog: return "cloud.fog.fill"
        case .clear: return "moon.stars.fill"
        }
    }
}

struct SettingsView: View {
    enum Tab: String, CaseIterable { case sky = "Sky", snow = "Snow", plow = "Plow", more = "More" }

    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var weather: WeatherService
    @State private var tab: Tab

    init(model: AppModel) {
        self.model = model
        prefs = model.prefs
        weather = model.weather
        let env = ProcessInfo.processInfo.environment["SNOWSILL_TAB"]
        _tab = State(initialValue: Tab(rawValue: env ?? model.prefs.lastTab) ?? .sky)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .onChange(of: tab) { _, t in prefs.lastTab = t.rawValue }

            Group {
                switch tab {
                case .sky: SkyTab(model: model, prefs: prefs, weather: weather)
                case .snow: SnowTab(prefs: prefs)
                case .plow: PlowTab(model: model, prefs: prefs)
                case .more: MoreTab(model: model, prefs: prefs)
                }
            }
            .padding(16)
            .disabled(!prefs.enabled)
            .opacity(prefs.enabled ? 1 : 0.45)

            Divider()
            HStack {
                Button { model.clearSnow() } label: { Label("Clear the snow", systemImage: "wind") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Vibe.glow)
                Image(systemName: currentScene.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .saturation(prefs.enabled ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text("Snowsill").font(Vibe.title(17))
                Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $prefs.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Vibe.lilac)
                .help("Turn the weather on or off (⌃⌥⌘S)")
        }
    }

    private var currentScene: Scene { model.scene }

    private var statusLine: String {
        if !prefs.enabled { return "Off. Flip the switch to start." }
        if let note = model.scheduleNote { return note }
        if !model.running { return "Paused" }
        switch currentScene {
        case .snow: return prefs.mode == .live && weather.current != nil ? "Snowing in \(weatherPlace)" : "Snowing on your desktop"
        case .rain: return prefs.mode == .live && weather.current != nil ? "Raining in \(weatherPlace)" : "Raining on your desktop"
        case .fog: return "Foggy and quiet"
        case .clear: return prefs.mode == .live && weather.current != nil ? "Clear skies in \(weatherPlace)" : "Clear skies"
        }
    }

    private var weatherPlace: String { weather.place.components(separatedBy: ",").first ?? weather.place }
}

// MARK: - Sky

private struct SkyTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var weather: WeatherService
    @State private var cityDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(Scene.allCases) { s in
                    SceneTile(scene: s, selected: model.scene == s) { model.setScene(s) }
                        .disabled(prefs.mode == .live && weather.current != nil)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Match the weather in my city", isOn: Binding(
                    get: { prefs.mode == .live },
                    set: { prefs.mode = $0 ? .live : .manual }))
                    .toggleStyle(.switch).controlSize(.small).tint(Vibe.lilac)
                if prefs.mode == .live {
                    HStack {
                        TextField("City, like Tokyo or Oslo", text: $cityDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(setCity)
                        Button("Set", action: setCity)
                            .disabled(cityDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text(weather.status).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            NiceSlider(title: model.scene == .rain ? "How much rain" : "How much snow", value: $prefs.intensity,
                       low: "A few flakes", high: "Blizzard")
            if prefs.mode == .manual {
                NiceSlider(title: "Wind", value: $prefs.wind, range: -1...1, low: "Blows left", high: "Blows right",
                           format: { v in abs(v) < 0.05 ? "Still" : "\(Int(abs(v) * 100))% \(v > 0 ? "→" : "←")" })
                if model.scene != .fog {
                    NiceSlider(title: "Mist", value: $prefs.fog, low: "None", high: "Thick")
                }
            }
        }
        .onAppear { cityDraft = prefs.city }
    }

    private func setCity() {
        prefs.city = cityDraft
        weather.setCity(cityDraft)
    }
}

private struct SceneTile: View {
    let scene: Scene
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: scene.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(scene.label).font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .foregroundStyle(selected ? .white : .primary)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Vibe.glow) : AnyShapeStyle(.quaternary.opacity(0.6)))
                    .shadow(color: selected ? Vibe.lilac.opacity(0.55) : .clear, radius: 10, y: 3)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(enabled || selected ? 1 : 0.5)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(scene.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Snow

private struct SnowTab: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Snow settles on").font(.subheadline.weight(.semibold))
                HStack(spacing: 14) {
                    Toggle("Windows", isOn: $prefs.pileOnWindows)
                    Toggle("The Dock", isOn: $prefs.pileOnDock)
                    Toggle("Desktop widgets & icons", isOn: $prefs.pileOnDesktop)
                }
                .toggleStyle(.checkbox)
            }
            NiceSlider(title: "How high it piles", value: $prefs.pile, low: "A dusting", high: "Deep drifts")
            NiceSlider(title: "How fast it melts", value: $prefs.melt, low: "Never", high: "Quickly")
            NiceSlider(title: "Flake size", value: $prefs.flakeSize, range: 0.6...1.6, low: "Tiny", high: "Big & fluffy",
                       format: { String(format: "%.1f×", $0) })

            VStack(alignment: .leading, spacing: 6) {
                Text("Little extras").font(.subheadline.weight(.semibold))
                HStack(spacing: 14) {
                    Toggle("Icicles", isOn: $prefs.icicles)
                    Toggle("Snowman", isOn: $prefs.snowman)
                    Toggle("Frosty corners", isOn: $prefs.frost)
                }
                .toggleStyle(.checkbox)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Falling snow shows").font(.subheadline.weight(.semibold))
                Picker("", selection: $prefs.desktopOnly) {
                    Text("Over everything").tag(false)
                    Text("Only on the desktop").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            ExemptAppsRow(prefs: prefs)
        }
    }
}

// MARK: - Plow

private struct PlowTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 10) {
                Image(nsImage: model.truckPreview)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 64)
                    .padding(.top, 6)
                Text(model.plowVisible ? "On its way. It clears the bottom of your screen, then drives off."
                                       : "A little plow that clears the snow from the bottom of your screen.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.togglePlow()
                } label: {
                    Text(model.plowVisible ? "Clearing…" : "Call the plow")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Vibe.coral)
                .controlSize(.large)
                .disabled(model.plowVisible)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.45)))

            Toggle("Come by itself when the snow gets deep", isOn: $prefs.autoPlow)
                .toggleStyle(.switch).controlSize(.small).tint(Vibe.lilac)
            if prefs.autoPlow {
                NiceSlider(title: "Comes when snow reaches", value: $prefs.plowAt, low: "A dusting", high: "Deep drifts",
                           format: { _ in "\(model.plowTriggerDepth) pt" })
            }
        }
    }
}

// MARK: - More

private struct MoreTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("Push snow around with the pointer", isOn: $prefs.pointer)
            Toggle("Soft sounds (wind and the plow)", isOn: $prefs.sounds)
            Toggle("Shortcut ⌃⌥⌘S turns it on and off", isOn: $prefs.hotkey)
            Toggle("Pause while an app is full screen", isOn: $prefs.pauseFullscreen)
            Toggle("Pause on battery", isOn: $prefs.pauseOnBattery)
            Toggle("Open when I log in", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Toggle("Show in Dock (the menu-bar snowflake always stays)", isOn: $prefs.showInDock)
            #if !APPSTORE
            Toggle("Precise Dock and desktop icons (asks for Accessibility)", isOn: $prefs.exactDock)
            #endif
            DisplaysSection(prefs: prefs)
            HStack {
                Text("When it shows")
                Spacer()
                Picker("", selection: $prefs.schedule) {
                    Text("Always").tag(Preferences.Schedule.always)
                    Text("Winter months").tag(Preferences.Schedule.winter)
                    Text("Evenings").tag(Preferences.Schedule.evenings)
                }
                .labelsHidden().fixedSize()
            }
            .padding(.top, 2)

            if model.updater.isAvailable {
                HStack {
                    Toggle("Install updates automatically", isOn: Binding(
                        get: { model.updater.automatic }, set: { model.updater.automatic = $0 }))
                    Spacer()
                    Button("Check now") { model.updater.checkNow() }
                        .controlSize(.small)
                }
            }

            Divider().padding(.vertical, 4)
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Snowsill \(Bundle.main.shortVersion)").font(.subheadline.weight(.semibold))
                    Text("Developed by Lakshya Badjatya").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: URL(string: "https://github.com/LakshyaBadjatya/Snowsill")!) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .help("Source code on GitHub")
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(Vibe.lilac)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
}

// MARK: - Shared controls

private struct NiceSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    let low: String
    let high: String
    var format: ((Double) -> String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(valueText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range).controlSize(.small).tint(Vibe.lilac)
            HStack { Text(low); Spacer(); Text(high) }
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var valueText: String {
        if let format { return format(value) }
        return "\(Int(((value - range.lowerBound) / (range.upperBound - range.lowerBound) * 100).rounded()))%"
    }
}

/// Apps whose windows never get snow over or on them.
private struct ExemptAppsRow: View {
    @ObservedObject var prefs: Preferences
    @State private var open = ProcessInfo.processInfo.environment["SNOWSILL_EXEMPT_OPEN"] == "1"

    private struct AppItem: Identifiable { let id: String; let name: String; let icon: NSImage? }

    private var apps: [AppItem] {
        var seen = Set<String>()
        var out: [AppItem] = []
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
            guard let id = a.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { continue }
            out.append(AppItem(id: id, name: a.localizedName ?? id, icon: a.icon))
        }
        for id in prefs.exemptApps where !seen.contains(id) {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            out.append(AppItem(id: id, name: name, icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Keep snow off these apps").font(.subheadline.weight(.semibold))
                        Text(prefs.exemptApps.isEmpty ? "None yet. Pick apps where you never want snow."
                                                      : "\(prefs.exemptApps.count) app\(prefs.exemptApps.count == 1 ? "" : "s") kept snow-free")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                let list = apps
                if list.isEmpty {
                    Text("Open an app and it will show up here.").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(list) { app in
                            Toggle(isOn: Binding(
                                get: { prefs.exemptApps.contains(app.id) },
                                set: { on in
                                    if on { if !prefs.exemptApps.contains(app.id) { prefs.exemptApps.append(app.id) } }
                                    else { prefs.exemptApps.removeAll { $0 == app.id } }
                                })) {
                                HStack(spacing: 6) {
                                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                                    Text(app.name).font(.callout).lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(CGFloat(list.count) * 24 + 6, 168))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.35)))
            }
        }
    }
}


/// One switch per display. Remembered by the display's name, so a monitor
/// keeps its setting when it is unplugged and plugged back in.
private struct DisplaysSection: View {
    @ObservedObject var prefs: Preferences
    @State private var screens: [String] = NSScreen.screens.map(\.localizedName)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(screens.count > 1 ? "Snow on these displays" : "Display").font(.subheadline.weight(.semibold))
            ForEach(screens, id: \.self) { name in
                Toggle(isOn: Binding(
                    get: { !prefs.disabledDisplays.contains(name) },
                    set: { on in
                        if on { prefs.disabledDisplays.removeAll { $0 == name } }
                        else if !prefs.disabledDisplays.contains(name) { prefs.disabledDisplays.append(name) }
                    })) {
                    Label(name, systemImage: name.localizedCaseInsensitiveContains("built-in") ? "laptopcomputer" : "display")
                }
            }
            if screens.count == 1 {
                Text("Plug in another screen and you can pick where it snows.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens.map(\.localizedName)
        }
    }
}
