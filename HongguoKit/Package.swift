// swift-tools-version:5.9
import PackageDescription

// Shared by the Mac app (macos/), the iOS app and the coming tvOS app. One behavior for all of
// them: the official iOS 7.4.3 client's play logic, no per-platform switches.
let package = Package(
    name: "HongguoKit",
    platforms: [.macOS(.v14), .iOS("26.0"), .tvOS("26.0")],
    products: [
        .library(name: "HongguoCore", targets: ["HongguoCore"]),
        .library(name: "HongguoPlayback", targets: ["HongguoPlayback"]),
        .library(name: "AppLogic", targets: ["AppLogic"]),
        .library(name: "HongguoModels", targets: ["HongguoModels"]),
    ],
    targets: [
        // Models, signing, App and website sources, identity, CDN candidates, caches.
        .target(name: "HongguoCore", path: "Sources/HongguoCore"),
        // Hongguo episode resolving and the decrypt-while-streaming loader (from the iOS app).
        .target(name: "HongguoPlayback", dependencies: ["HongguoCore"], path: "Sources/HongguoPlayback"),
        // The apps' pure rules with no UI or network (from the iOS app's Logic/): feed and series
        // advance, gesture math, sleep timer, sync and merge rules.
        .target(name: "AppLogic", path: "Sources/AppLogic"),
        // The apps' shared models with no UI (from the iOS app): the data backend and its offline
        // samples, the account (sign-in state, lists, queued writes, session isolation), what the
        // viewer keeps (LibraryModel), QR sign-in and the common launch switches.
        .target(name: "HongguoModels", dependencies: ["HongguoCore", "HongguoPlayback", "AppLogic"],
                path: "Sources/HongguoModels"),
        .testTarget(name: "HongguoCoreTests", dependencies: ["HongguoCore"],
                    path: "Tests/HongguoCoreTests", exclude: ["Fixtures"]),
        .testTarget(name: "HongguoPlaybackTests", dependencies: ["HongguoPlayback"], path: "Tests/HongguoPlaybackTests"),
        .testTarget(name: "AppLogicTests", dependencies: ["AppLogic"], path: "Tests/AppLogicTests"),
        .testTarget(name: "HongguoModelsTests", dependencies: ["HongguoModels"], path: "Tests/HongguoModelsTests"),
        // Live probes of the App catalogue and playback, skipped unless HONGGUO_PROBE is set.
        .testTarget(name: "HongguoProbeTests", dependencies: ["HongguoCore", "HongguoPlayback"], path: "Tests/HongguoProbeTests"),
    ]
)
