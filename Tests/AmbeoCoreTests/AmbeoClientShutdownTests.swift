import Foundation
import Testing

@testable import AmbeoCore

@Suite("AmbeoClient Shutdown Tests") struct AmbeoClientShutdownTests {
  private func client() -> AmbeoClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HangingProtocol.self]
    return AmbeoClient(host: "test.local", configuration: config)
  }

  @Test("A shut-down client fails fast instead of reaching the network")
  func failsFastAfterShutdown() async {
    let client = client()
    await client.shutdown()

    do {
      try await client.set(
        AmbeoEndpoint.Player.Mute(),
        valueJSON: #"{"type":"bool_","bool_":true}"#
      )
      Issue.record("expected the write to fail after shutdown")
    } catch let error as URLError { #expect(error.code == .cancelled) } catch {
      Issue.record("unexpected error: \(error)")
    }

    // Reads must not touch an invalidated session either.
    #expect(await client.getValue(for: AmbeoEndpoint.Player.Mute()) == nil)
  }

  @Test("Shutdown is idempotent") func idempotent() async {
    let c = client()
    await c.shutdown()
    await c.shutdown()
  }
}
