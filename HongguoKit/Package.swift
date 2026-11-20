// swift-tools-version:5.9
// HongguoKit: the code shared by the native apps (macOS today; iOS and tvOS to follow).
// HongguoCore holds networking, signing, source lookup, parsing, decryption and persistence,
// with no UI imports. See README.md for the plan.
import PackageDescription

let package = Package(
    name: "HongguoKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HongguoCore", targets: ["HongguoCore"]),
    ],
    targets: [
        // Networking, parsing, decryption and persistence. No UI imports, so it stays unit-testable.
        .target(name: "HongguoCore", path: "Sources/HongguoCore"),
        .testTarget(
            name: "HongguoCoreTests",
            dependencies: ["HongguoCore"],
            path: "Tests/HongguoCoreTests",
            exclude: ["Fixtures"]
        ),
    ]
)
