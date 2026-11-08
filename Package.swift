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
    // Core
    .target(
      name: "AmbeoCore",
      dependencies: [.product(name: "Logging", package: "swift-log")],
      path: "Sources/AmbeoCore"
    ), .testTarget(name: "AmbeoCoreTests", dependencies: ["AmbeoCore"]),
    // The app itself (AppModel, SwiftUI scenes, views, delegate). It is a library target on
    // purpose: SPM refuses a test target for an executableTarget, and AppModel holds the
    // reconnect / telemetry / Atmos Boost logic that needs real tests.
    .target(
      name: "AmbeoApp",
      dependencies: [
        "AmbeoCore", .product(name: "Logging", package: "swift-log"),
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
      ],
      path: "Sources/AmbeoApp"
    ), .testTarget(name: "AmbeoAppTests", dependencies: ["AmbeoApp", "AmbeoCore"]),
    // Thin shim: main.swift calls AmbeoAppMain.run().
    .executableTarget(
      name: "AmbeoCompanion",
      dependencies: ["AmbeoApp"],
      path: "Sources/AmbeoCompanion",
      exclude: ["Info.plist", "AmbeoCompanion.entitlements", "Resources"]
    ),
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
