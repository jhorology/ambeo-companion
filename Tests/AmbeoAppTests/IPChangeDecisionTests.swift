import Foundation
import Testing

@testable import AmbeoApp

/// The reconnect decision behind `debouncedReconnectIfIPChanged`. A wrong answer here tears down a
/// live session, which is why it is a pure function with tests.
@Suite("Soundbar IP Change Decision") struct IPChangeDecisionTests {
  @Test("Only a concrete, different address triggers a reconnect") func differingAddress() {
    #expect(AppModel.shouldReconnectForIPChange(host: "192.168.0.20", discoveredIP: "192.168.0.31"))
    #expect(
      !AppModel.shouldReconnectForIPChange(host: "192.168.0.20", discoveredIP: "192.168.0.20")
    )
  }

  @Test("No client, no device, and empty addresses never trigger a reconnect") func missingValues()
  {
    // A nil host means there is nothing connected to reconnect.
    #expect(!AppModel.shouldReconnectForIPChange(host: nil, discoveredIP: "192.168.0.31"))
    // A nil IP means the selected device is not in the discovery list right now.
    #expect(!AppModel.shouldReconnectForIPChange(host: "192.168.0.20", discoveredIP: nil))
    #expect(!AppModel.shouldReconnectForIPChange(host: "", discoveredIP: "192.168.0.31"))
    #expect(!AppModel.shouldReconnectForIPChange(host: "192.168.0.20", discoveredIP: ""))
  }
}
