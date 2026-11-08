import Foundation
import Testing

@testable import AmbeoApp

/// 🟡13: Quit must not hang behind an unresponsive soundbar.
/// Lock-guarded flag so a `@Sendable` work closure can report completion.
private final class RanFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  var didRun: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

@Suite("Termination Grace Period") struct TerminationGuardTests {
  @Test("Cleanup that finishes in time is reported as finished") func fastCleanup() async {
    let ran = RanFlag()
    let finished = await TerminationGuard.run(grace: .seconds(2)) {
      try? await Task.sleep(for: .milliseconds(10))
      ran.set()
    }
    #expect(finished)
    #expect(ran.didRun)
  }

  @Test("Cleanup that outlives the grace period returns and lets the app quit") func hungCleanup()
    async
  {
    let started = ContinuousClock.now
    let finished = await TerminationGuard.run(grace: .milliseconds(120)) {
      // Stands in for a setData call stuck behind an unreachable soundbar.
      try? await Task.sleep(for: .seconds(30))
    }
    let elapsed = started.duration(to: .now)
    #expect(!finished)
    #expect(elapsed < .seconds(2))
  }

  @Test("The production grace period stays short enough that Quit feels responsive")
  func productionGrace() { #expect(TerminationGuard.grace <= .seconds(3)) }
}
