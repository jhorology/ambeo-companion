import Foundation
import Testing

@testable import AmbeoCore

/// 🟡6: the AMBEO remembers its volume across standby and power loss, so the ledger must survive
/// every app-side event. Clearing it on a power cycle makes the next Atmos transition boost the
/// already-boosted volume (double boost = loud output).
@MainActor @Suite("Atmos Boost Ledger") struct AtmosBoostLedgerTests {
  private func defaults(_ name: String) -> UserDefaults {
    let suite = UserDefaults(suiteName: "io.github.jhorology.AmbeoCompanion.tests.\(name)")!
    suite.removePersistentDomain(forName: "io.github.jhorology.AmbeoCompanion.tests.\(name)")
    return suite
  }

  @Test("Amounts are tracked per soundbar") func perDevice() {
    let ledger = AtmosBoostLedger(defaults: defaults(#function), key: "ledger")
    ledger.record(10, for: "mini-a")
    #expect(ledger.amount(for: "mini-a") == 10)
    #expect(ledger.amount(for: "mini-b") == 0)
  }

  @Test("The ledger survives a relaunch, so a restart cannot double-boost the volume")
  func survivesRelaunch() {
    let suite = defaults(#function)
    AtmosBoostLedger(defaults: suite, key: "ledger").record(15, for: "mini-a")
    // A new process reads the same store: reconnect, wake from sleep and standby -> online all
    // keep the recorded boost.
    #expect(AtmosBoostLedger(defaults: suite, key: "ledger").amount(for: "mini-a") == 15)
  }

  @Test("Recording 0 is the only way to clear an entry, and negatives clamp") func clearing() {
    let ledger = AtmosBoostLedger(defaults: defaults(#function), key: "ledger")
    ledger.record(8, for: "mini-a")
    ledger.record(-3, for: "mini-a")
    #expect(ledger.amount(for: "mini-a") == 0)
  }

  @Test("An empty uid is ignored, so an unconnected app cannot write a phantom entry")
  func emptyUid() {
    let suite = defaults(#function)
    let ledger = AtmosBoostLedger(defaults: suite, key: "ledger")
    ledger.record(10, for: "")
    #expect(suite.dictionary(forKey: "ledger") == nil)
  }
}
