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
            dependencies: [.product(name: "HongguoCore", package: "HongguoKit")],
            path: "Sources/HongguoDrama"
        ),
    ]
)
