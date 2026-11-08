import AmbeoCore
import Foundation
import Logging

/// Runs termination cleanup against a deadline, so an unresponsive soundbar cannot hang Quit.
///
/// Interrupting the cleanup is safe: the Atmos Boost ledger and the mute recovery state are
/// cleared only after a successful write, so unfinished work stays recorded and is retried on the
/// next launch or reconnect.
enum TerminationGuard {
  static let grace: Duration = .seconds(2.5)

  /// Returns true when `work` finished inside the grace period.
  @discardableResult static func run(
    grace: Duration = grace,
    work: @escaping @Sendable () async -> Void
  ) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await work()
        return true
      }
      group.addTask {
        try? await Task.sleep(for: grace)
        return false
      }
      let finished = await group.next() ?? false
      group.cancelAll()
      if !finished {
        Logger.lifecycle.warning(
          "Termination cleanup exceeded the grace period; quitting with unfinished work."
        )
      }
      return finished
    }
  }
}
