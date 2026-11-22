import Foundation

#if canImport(Sparkle) && !APPSTORE
import Sparkle

/// Automatic updates (direct download build) with Sparkle 2. Every update is
/// signed; Snowsill checks on every launch and once a day, downloads quietly
/// and installs when it quits or relaunches.
final class Updater: NSObject, ObservableObject {
    private let controller: SPUStandardUpdaterController

    override init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    var isAvailable: Bool { true }

    func start() {
        let u = controller.updater
        u.automaticallyChecksForUpdates = true
        u.automaticallyDownloadsUpdates = true
        u.updateCheckInterval = 24 * 60 * 60
        do { try u.start() } catch { NSLog("Snowsill: updater could not start: \(error)") }
        // Check on every launch, not only when the daily interval has passed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { u.checkForUpdatesInBackground() }
    }

    func checkNow() { controller.checkForUpdates(nil) }

    var automatic: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            controller.updater.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }
}
#else
/// Mac App Store build: the App Store handles updates.
final class Updater: NSObject, ObservableObject {
    var isAvailable: Bool { false }
    func start() {}
    func checkNow() {}
    var automatic: Bool { get { false } set {} }
}
#endif
