// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Holo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HoloCore", targets: ["HoloCore"]),
        .executable(name: "HoloSoak", targets: ["HoloSoak"]),
        .executable(name: "HoloReplay", targets: ["HoloReplay"])
    ],
    targets: [
        .target(name: "HoloCore", path: "Sources/HoloCore"),
        .executableTarget(
            name: "HoloSoak",
            dependencies: ["HoloCore"],
            path: "Sources/HoloSoak"
        ),
        .target(
            name: "HoloReplaySupport",
            dependencies: ["HoloCore"],
            path: "Sources/HoloReplaySupport"
        ),
        .executableTarget(
            name: "HoloReplay",
            dependencies: ["HoloCore", "HoloReplaySupport"],
            path: "Sources/HoloReplay"
        ),
        .testTarget(
            name: "HoloCoreTests",
            dependencies: ["HoloCore"],
            path: "Tests/HoloCoreTests"
        ),
        .testTarget(
            name: "HoloReplayTests",
            dependencies: ["HoloReplaySupport", "HoloCore"],
            path: "Tests/HoloReplayTests"
        )
    ]
)
