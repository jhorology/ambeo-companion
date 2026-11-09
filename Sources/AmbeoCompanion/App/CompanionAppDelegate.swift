import AmbeoCore
import AppKit
import Foundation
import Logging

extension Bundle {
  static var id: String { main.bundleIdentifier ?? "io.github.jhorology.ambeo-companion.dev" }
}

@MainActor final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
  private var isTerminating = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model = AppModel.runningInstance else { return .terminateNow }
    guard !isTerminating else { return .terminateLater }
    isTerminating = true
    Task {
      await TerminationGuard.run(work: { await model.prepareForTermination() })
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
