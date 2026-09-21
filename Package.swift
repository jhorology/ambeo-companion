// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "AmbeoCompanion",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
  ],
  targets: [
    // Core
    .target(
      name: "AmbeoCore",
      dependencies: [
        .product(name: "Logging", package: "swift-log")
      ],
      path: "Sources/AmbeoCore"
    ),
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    .executableTarget(
      name: "AmbeoCompanion",
      dependencies: [
        "AmbeoCore",
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
      ],
      path: "Sources/AmbeoCompanion",
      exclude: ["Info.plist", "Resources"]
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
