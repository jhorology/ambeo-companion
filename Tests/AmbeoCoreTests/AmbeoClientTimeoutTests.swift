import Foundation
import Testing

@testable import AmbeoCore

/// Answers nothing for 5 s, so a caller's per-request timeout is the only thing that ends the call.
private final class HangingProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self else { return }
      self.client?.urlProtocol(
        self,
        didLoad: Data(#"{"value":{"type":"bool_","bool_":true}}"#.utf8)
      )
      self.client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

@Suite("AmbeoClient Request Timeout Tests") struct AmbeoClientTimeoutTests {
  private func hangingClient() -> AmbeoClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HangingProtocol.self]
    return AmbeoClient(host: "test.local", configuration: config)
  }

  @Test("A mute write honours the interactive timeout instead of the session-wide 10 s window")
  func muteWriteTimesOutFast() async throws {
    let client = hangingClient()
    let started = ContinuousClock.now
    do {
      try await client.set(
        AmbeoEndpoint.Player.Mute(),
        valueJSON: #"{"type":"bool_","bool_":true}"#,
        timeout: 0.4
      )
      Issue.record("expected the request to time out")
    } catch let error as URLError { #expect(error.code == .timedOut) }
    let elapsed = started.duration(to: .now)
    // The Stealth Rewind mute window is bounded by this: it must not approach the 10 s default.
    #expect(elapsed < .seconds(2))
  }
}
