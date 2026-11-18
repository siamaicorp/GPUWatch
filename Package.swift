// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GPUWatch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GPUWatchCore", targets: ["GPUWatchCore"]),
        .library(name: "GPUWatchUI", targets: ["GPUWatchUI"]),
        .executable(name: "GPUWatch", targets: ["GPUWatch"]),
        .executable(name: "GPUWatchSnapshot", targets: ["GPUWatchSnapshot"])
    ],
    targets: [
        // Models, SSH, parsing, evaluation, polling, persistence. No UI.
        .target(
            name: "GPUWatchCore",
            path: "Sources/GPUWatchCore"
        ),
        // SwiftUI layers. A library so the snapshot tool can render the real
        // views rather than a reimplementation of them.
        .target(
            name: "GPUWatchUI",
            dependencies: ["GPUWatchCore"],
            path: "Sources/GPUWatchUI",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "GPUWatch",
            dependencies: ["GPUWatchUI"],
            path: "Sources/GPUWatch"
        ),
        // Visual QA harness. Renders the real views offscreen so the UI can be
        // inspected without clicking through the menu bar.
        .executableTarget(
            name: "GPUWatchSnapshot",
            dependencies: ["GPUWatchUI"],
            path: "Sources/GPUWatchSnapshot"
        ),
        .testTarget(
            name: "GPUWatchCoreTests",
            dependencies: ["GPUWatchCore"],
            path: "Tests/GPUWatchCoreTests"
        ),
        // The window controllers hold behaviour that regressed once already
        // (windows rebuilt on a timer), so they get their own coverage.
        .testTarget(
            name: "GPUWatchUITests",
            dependencies: ["GPUWatchUI", "GPUWatchCore"],
            path: "Tests/GPUWatchUITests"
        )
    ]
)
