// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HongguoDrama",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HongguoDrama", targets: ["HongguoDrama"]),
    ],
    dependencies: [
        // The shared core (networking, parsing, decryption, persistence) lives in ../HongguoKit
        // so the iOS and tvOS apps can use the same code.
        .package(path: "../HongguoKit"),
    ],
    targets: [
        // SwiftUI + AppKit + AVKit application shell.
        .executableTarget(
            name: "HongguoDrama",
            dependencies: [.product(name: "HongguoCore", package: "HongguoKit"), "MediaSources"],
            path: "Sources/HongguoDrama"
        ),
        // Catalogues other than Hongguo (西饭, 河马, ReelShort, DramaBox, custom Apple CMS
        // endpoints), used by this app only and kept out of the shared HongguoKit.
        .target(
            name: "MediaSources",
            dependencies: [.product(name: "HongguoCore", package: "HongguoKit")],
            path: "Sources/MediaSources"
        ),
        .testTarget(
            name: "MediaSourcesTests",
            dependencies: ["MediaSources", .product(name: "HongguoCore", package: "HongguoKit")],
            path: "Tests/MediaSourcesTests"
        ),
    ]
)
