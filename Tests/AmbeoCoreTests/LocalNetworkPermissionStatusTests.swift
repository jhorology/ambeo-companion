import Foundation
import Testing

@testable import AmbeoCore

@Suite("Local Network Permission Inference") struct LocalNetworkPermissionStatusTests {
  private func instant(ago: Duration) -> ContinuousClock.Instant { ContinuousClock.now - ago }

  @Test("Discovery results prove the permission works") func allowed() {
    #expect(
      LocalNetworkPermissionStatus(deviceCount: 1, hasClient: false, startedAt: nil) == .allowed
    )
    #expect(
      LocalNetworkPermissionStatus(deviceCount: 0, hasClient: true, startedAt: nil) == .allowed
    )
  }

  @Test("An empty result list inside the grace period is still probing") func probing() {
    #expect(
      LocalNetworkPermissionStatus(deviceCount: 0, hasClient: false, startedAt: nil) == .probing
    )
    #expect(
      LocalNetworkPermissionStatus(
        deviceCount: 0,
        hasClient: false,
        startedAt: instant(ago: .seconds(4)),
        grace: .seconds(15)
      ) == .probing
    )
  }

  @Test("An empty result list after the grace period is reported as nothing found")
  func nothingFound() {
    #expect(
      LocalNetworkPermissionStatus(
        deviceCount: 0,
        hasClient: false,
        startedAt: instant(ago: .seconds(20)),
        grace: .seconds(15)
      ) == .nothingFound
    )
    // The grace window is what separates "just launched" from "silently denied".
    #expect(
      LocalNetworkPermissionStatus(
        deviceCount: 0,
        hasClient: false,
        startedAt: instant(ago: .seconds(20)),
        grace: .seconds(30)
      ) == .probing
    )
  }

  @Test("The UI mapping flags only the warning state") func uiMapping() {
    #expect(LocalNetworkPermissionStatus.allowed.label == "Allowed")
    #expect(LocalNetworkPermissionStatus.probing.label == "Checking…")
    #expect(LocalNetworkPermissionStatus.nothingFound.label == "No soundbar found")
    #expect(!LocalNetworkPermissionStatus.allowed.isWarning)
    #expect(!LocalNetworkPermissionStatus.probing.isWarning)
    #expect(LocalNetworkPermissionStatus.nothingFound.isWarning)
    #expect(!LocalNetworkPermissionStatus.allowed.symbol.isEmpty)
  }
}
