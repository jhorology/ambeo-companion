import AmbeoCore
import Foundation
import XCTest

private final class RecoveringProtocol: URLProtocol, @unchecked Sendable {
  static let lock = NSLock()
  nonisolated(unsafe) static var requests = 0
  nonisolated(unsafe) static var useArray = false
  nonisolated(unsafe) static var hardwareVolume = 25
  static let entry = """
    {"value":{"type":"i32_","i32_":25},"edit":{"step":"1","min":"0","max":"100"}}
    """

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let (count, array, volume) = Self.lock.withLock {
      Self.requests += 1
      if request.url?.path == "/api/setData",
        let value = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
          .first(where: { $0.name == "value" })?.value,
        let data = value.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let volume = object["i32_"] as? Int
      {
        Self.hardwareVolume = volume
      }
      return (Self.requests, Self.useArray, Self.hardwareVolume)
    }
    if count == 1 {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    } else {
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(
        self,
        didLoad: Data(
          (array ? "[\(Self.entry)]" : Self.entry).replacingOccurrences(
            of: "\"i32_\":25",
            with: "\"i32_\":\(volume)"
          ).utf8
        )
      )
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}

private final class FailFirstHardwareProtocol: URLProtocol, @unchecked Sendable {
  static let lock = NSLock()
  nonisolated(unsafe) static var failed = false
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let shouldFail = Self.lock.withLock {
      if Self.failed { return false }
      Self.failed = true
      return true
    }
    if shouldFail {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    URLSession.shared.dataTask(with: request) { [self] data, response, error in
      if let error {
        client?.urlProtocol(self, didFailWithError: error)
      } else if let data, let response {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      }
    }.resume()
  }

  override func stopLoading() {}
}

final class RecoveryTests: XCTestCase {
  func testInitialFailureRecoversVolumeMetadata() async {
    await checkRecovery(array: false)
  }

  func testInitialFailureRecoversArrayResponse() async {
    await checkRecovery(array: true)
  }

  private func checkRecovery(array: Bool) async {
    RecoveringProtocol.lock.withLock {
      RecoveringProtocol.requests = 0
      RecoveringProtocol.useArray = array
      RecoveringProtocol.hardwareVolume = 25
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RecoveringProtocol.self]
    let client = AmbeoClient(host: "test.local", configuration: config)
    await client.register(AmbeoEndpoint.Player.Volume())
    let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume())
    XCTAssertEqual(entry?.value, 25)
    XCTAssertEqual(entry?.edit?.step, 1)
    let volume = await client.state.volume
    XCTAssertEqual(volume, 25)
  }

  func testCleanupReadsFreshVolumeAndClampsAtMinimum() async throws {
    RecoveringProtocol.lock.withLock {
      RecoveringProtocol.requests = 1
      RecoveringProtocol.useArray = false
      RecoveringProtocol.hardwareVolume = 25
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RecoveringProtocol.self]
    let client = AmbeoClient(host: "test.local", configuration: config)
    await client.register(AmbeoEndpoint.Player.Volume())
    RecoveringProtocol.lock.withLock { RecoveringProtocol.hardwareVolume = 40 }
    let removed = try await client.removeVolumeBoost(10)
    XCTAssertTrue(removed)
    let volume = await client.state.volume
    XCTAssertEqual(volume, 30)
    let clamped = try await client.removeVolumeBoost(50)
    XCTAssertTrue(clamped)
    let minimum = await client.state.volume
    XCTAssertEqual(minimum, 0)
  }

  @MainActor
  func testBoostSurvivesRestartAndStaysWithOriginalDevice() {
    let suite = "AmbeoTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let ledger = AtmosBoostLedger(defaults: defaults, key: "boost")
    ledger.record(20, for: "A")
    let restarted = AtmosBoostLedger(defaults: defaults, key: "boost")
    XCTAssertEqual(restarted.amount(for: "A"), 20)
    XCTAssertEqual(restarted.amount(for: "B"), 0)
    restarted.record(5, for: "B")
    restarted.record(0, for: "A")
    XCTAssertEqual(restarted.amount(for: "A"), 0)
    XCTAssertEqual(restarted.amount(for: "B"), 5)
  }

  func testAtmosAndMultichannelMustNotFallback() {
    XCTAssertTrue(
      AudioPhysicalFormat(channels: 2, bitDepth: 16, sampleRate: 192000, formatID: 0x6363_2b33)
        .isAtmosOrMultichannel
    )
    XCTAssertTrue(
      AudioPhysicalFormat(channels: 8, bitDepth: 24, sampleRate: 48000).isAtmosOrMultichannel
    )
    XCTAssertFalse(
      AudioPhysicalFormat(channels: 2, bitDepth: 24, sampleRate: 48000).isAtmosOrMultichannel
    )
  }

  func testHardwareRecoveryAfterInjectedInitialFailure() async throws {
    guard ProcessInfo.processInfo.environment["AMBEO_INTEGRATION"] == "1" else {
      throw XCTSkip("Set AMBEO_INTEGRATION=1 to test the real soundbar")
    }
    FailFirstHardwareProtocol.lock.withLock { FailFirstHardwareProtocol.failed = false }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FailFirstHardwareProtocol.self]
    let client = AmbeoClient(host: "ambeo.local", configuration: config)
    await client.register(AmbeoEndpoint.Player.Volume())
    let recovered = await client.getEntry(for: AmbeoEndpoint.Player.Volume())
    XCTAssertNotNil(recovered?.value)
    XCTAssertEqual(recovered?.edit?.step, 1)
    XCTAssertEqual(recovered?.edit?.max, 100)
  }

  func testHardwareVolumeRoundTrip() async throws {
    guard ProcessInfo.processInfo.environment["AMBEO_INTEGRATION"] == "1" else {
      throw XCTSkip("Set AMBEO_INTEGRATION=1 to test the real soundbar")
    }
    let client = AmbeoClient(host: "ambeo.local")
    await client.register(AmbeoEndpoint.Player.Volume())
    let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume())
    let original = try XCTUnwrap(entry?.value)
    guard original > 0 else { throw XCTSkip("Cannot lower zero volume") }
    let lower = original - 1
    try await client.set(
      AmbeoEndpoint.Player.Volume(),
      valueJSON: "{\"type\":\"i32_\",\"i32_\":\(lower)}"
    )
    let observed = AmbeoClient(host: "ambeo.local")
    await observed.register(AmbeoEndpoint.Player.Volume())
    let changed = await observed.state.volume
    // Restore before asserting so an assertion failure does not leave the volume changed.
    try await client.set(
      AmbeoEndpoint.Player.Volume(),
      valueJSON: "{\"type\":\"i32_\",\"i32_\":\(original)}"
    )
    let restored = AmbeoClient(host: "ambeo.local")
    await restored.register(AmbeoEndpoint.Player.Volume())
    let finalVolume = await restored.state.volume
    // Treat the original value as a one-step boost over the lowered baseline.
    let removed = try await client.removeVolumeBoost(1)
    let cleaned = AmbeoClient(host: "ambeo.local")
    await cleaned.register(AmbeoEndpoint.Player.Volume())
    let cleanedVolume = await cleaned.state.volume
    try await client.set(
      AmbeoEndpoint.Player.Volume(),
      valueJSON: "{\"type\":\"i32_\",\"i32_\":\(original)}"
    )
    XCTAssertTrue(removed)
    XCTAssertEqual(cleanedVolume, lower)
    XCTAssertEqual(changed, lower)
    XCTAssertEqual(finalVolume, original)
  }
}
