import SwiftUI
import AppKit

/// First-launch welcome: what Snowsill does and where to find it.
final class WelcomeWindow {
    private var window: NSWindow?

    func show(model: AppModel) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let view = WelcomeView(model: model) { [weak self] in self?.close() }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 490),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// The welcome screen as a plain view (used to render the README image).
    static func makeView(model: AppModel) -> NSView {
        NSHostingView(rootView: WelcomeView(model: model) {})
    }

    func close() {
        window?.close()
        window = nil
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: AppModel
    let done: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.055, green: 0.04, blue: 0.18), Vibe.night, Color(red: 0.29, green: 0.18, blue: 0.72)],
                           startPoint: .top, endPoint: .bottom)
            // Aurora glow: soft gradients (no blur, so it renders the same everywhere).
            EllipticalGradient(colors: [Color(red: 0.36, green: 0.95, blue: 0.78).opacity(0.35), .clear],
                               center: UnitPoint(x: 0.18, y: 0.12), startRadiusFraction: 0, endRadiusFraction: 0.55)
            EllipticalGradient(colors: [Vibe.lilac.opacity(0.45), .clear],
                               center: UnitPoint(x: 0.55, y: 0.05), startRadiusFraction: 0, endRadiusFraction: 0.6)
            EllipticalGradient(colors: [Vibe.coral.opacity(0.30), .clear],
                               center: UnitPoint(x: 0.92, y: 0.18), startRadiusFraction: 0, endRadiusFraction: 0.5)

            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 104, height: 104)
                    .shadow(color: Vibe.lilac.opacity(0.6), radius: 24, y: 8)
                    .padding(.top, 26)
                VStack(spacing: 6) {
                    Text("Let it snow on your Mac")
                        .font(Vibe.title(30))
                        .foregroundStyle(.white)
                    Text("Snow falls over your desktop and piles up on your windows and the Dock.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 460)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Point(symbol: "hand.point.up.left.fill", text: "Run your pointer through a pile to push the snow around.")
                    Point(symbol: "macwindow", text: "Drag a window and its snow tumbles off. Icicles snap.")
                    Point(symbol: "truck.box.fill", text: "When the bottom gets deep, a plow drives in and clears it. Swipe it yourself any time.")
                    Point(symbol: "snowflake", text: "Find Snowsill in the menu bar. ⌃⌥⌘S turns it on and off.")
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.top, 4)

                Button {
                    model.prefs.welcomed = true
                    model.prefs.enabled = true
                    done()
                } label: {
                    Text("Start the snow")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 34).padding(.vertical, 11)
                        .background(Capsule().fill(Vibe.glow))
                        .foregroundStyle(.white)
                        .shadow(color: Vibe.lilac.opacity(0.7), radius: 14, y: 4)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)

                Text("Developed by Lakshya Badjatya")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 16)
            }
        }
        .frame(width: 560, height: 490)
    }
}

private struct Point: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Vibe.ice)
                .frame(width: 22)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
