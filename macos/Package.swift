// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HongguoDrama",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HongguoDrama", targets: ["HongguoDrama"]),
        .library(name: "HongguoCore", targets: ["HongguoCore"]),
    ],
    targets: [
        // Networking, parsing, decryption and persistence. No UI imports, so it stays unit-testable.
        .target(name: "HongguoCore", path: "Sources/HongguoCore"),
        // SwiftUI + AppKit + AVKit application shell.
        .executableTarget(
            name: "HongguoDrama",
            dependencies: ["HongguoCore"],
            path: "Sources/HongguoDrama"
        ),
        .testTarget(
            name: "HongguoCoreTests",
            dependencies: ["HongguoCore"],
            path: "Tests/HongguoCoreTests"
        ),
    ]
)
