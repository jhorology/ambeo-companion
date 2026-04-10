import AmbeoCore
import Foundation
import Logging

extension Bundle {
  static var id: String {
    main.bundleIdentifier ?? "io.github.jhorology.ambeo-companion.dev"
  }
}

LogManager.setup(bid: Bundle.id)
Logger.lifecycle.debug("Start with Bundle ID: \(Bundle.id)")

AmbeoCompanionApp.main()
