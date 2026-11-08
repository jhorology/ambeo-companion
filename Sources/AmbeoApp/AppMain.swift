import AmbeoCore
import Foundation
import Logging

extension Bundle {
  public static var id: String {
    main.bundleIdentifier ?? "io.github.jhorology.ambeo-companion.dev"
  }
}

/// The executable target is a thin shim. SPM does not allow a test target for an
/// executableTarget, so the app (AppModel, scenes, views, delegate) lives in this library and
/// `Sources/AmbeoCompanion/main.swift` only calls `AmbeoAppMain.run()`. Keeping everything
/// `internal` here means no API surface had to be widened for tests (`@testable import AmbeoApp`).
public enum AmbeoAppMain {
  @MainActor public static func run() {
    LogManager.setup(bid: Bundle.id)
    Logger.lifecycle.debug("Start with Bundle ID: \(Bundle.id)")
    AmbeoCompanionApp.main()
  }
}
