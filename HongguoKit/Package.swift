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
    ],
    targets: [
        // Models, signing, App and website sources, identity, CDN candidates, caches.
        .target(name: "HongguoCore", path: "Sources/HongguoCore"),
        // Hongguo episode resolving and the decrypt-while-streaming loader (from the iOS app).
        .target(name: "HongguoPlayback", dependencies: ["HongguoCore"], path: "Sources/HongguoPlayback"),
        .testTarget(name: "HongguoCoreTests", dependencies: ["HongguoCore"],
                    path: "Tests/HongguoCoreTests", exclude: ["Fixtures"]),
        .testTarget(name: "HongguoPlaybackTests", dependencies: ["HongguoPlayback"], path: "Tests/HongguoPlaybackTests"),
        // Live probes of the App catalogue and playback, skipped unless HONGGUO_PROBE is set.
        .testTarget(name: "HongguoProbeTests", dependencies: ["HongguoCore"], path: "Tests/HongguoProbeTests"),
    ]
)
