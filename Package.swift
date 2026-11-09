// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "AmbeoCompanion",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "3.1.0"),
  ],
  targets: [
    // Core (app-independent reusable networking, CoreAudio, and system event primitives)
    .target(
      name: "AmbeoCore",
      dependencies: [.product(name: "Logging", package: "swift-log")],
      path: "Sources/AmbeoCore"
    ), .testTarget(name: "AmbeoCoreTests", dependencies: ["AmbeoCore"]),
    // Application (UI skeleton + feature coordinators)
    .executableTarget(
      name: "AmbeoCompanion",
      dependencies: [
        "AmbeoCore", .product(name: "Logging", package: "swift-log"),
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
      ],
      path: "Sources/AmbeoCompanion",
      exclude: ["Info.plist", "AmbeoCompanion.entitlements", "Resources"]
    ), .testTarget(name: "AmbeoCompanionTests", dependencies: ["AmbeoCompanion", "AmbeoCore"]),
    // Experiments
    .executableTarget(
      name: "DiscoverAmbeo",
      dependencies: ["AmbeoCore"],
      path: "Sources/Experiment/DiscoverAmbeo"
    ),
    .executableTarget(
      name: "FallbackAudioFormat",
      dependencies: ["AmbeoCore"],
      path: "Sources/Experiment/FallbackAudioFormat"
    ),
    .executableTarget(
      name: "HookVolumeAndMute",
      dependencies: ["AmbeoCore"],
      path: "Sources/Experiment/HookVolumeAndMute"
    ),
  ]
)
