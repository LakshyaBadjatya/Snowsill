// swift-tools-version:6.0
import PackageDescription
import Foundation

// SNOWSILL_APPSTORE=1 builds the Mac App Store flavour: sandboxed, no Sparkle
// (the App Store delivers updates itself), no Accessibility features.
let appStore = ProcessInfo.processInfo.environment["SNOWSILL_APPSTORE"] == "1"

var appDeps: [Target.Dependency] = ["SnowsillCore"]
var appSettings: [SwiftSetting] = []
var packageDeps: [Package.Dependency] = []
if appStore {
    appSettings.append(.define("APPSTORE"))
} else {
    packageDeps.append(.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"))
    appDeps.append(.product(name: "Sparkle", package: "Sparkle"))
}

let package = Package(
    name: "Snowsill",
    platforms: [.macOS(.v15)],
    dependencies: packageDeps,
    targets: [
        // Pure simulation: no AppKit, fully unit-tested.
        .target(name: "SnowsillCore"),
        // The menu-bar app: overlay windows, Metal renderer, settings UI.
        .executableTarget(
            name: "Snowsill",
            dependencies: appDeps,
            swiftSettings: appSettings,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "SnowsillCoreTests", dependencies: ["SnowsillCore"]),
    ],
    swiftLanguageModes: [.v5]
)
