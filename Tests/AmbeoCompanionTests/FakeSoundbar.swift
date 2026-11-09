import Foundation

@testable import AmbeoCompanion
@testable import AmbeoCore

/// A scripted AMBEO Mini. Answers `/api/getData` and `/api/setData` the way the firmware does
/// (writes travel in the query string of a GET) and records every write, so tests can assert that
/// a refused volume write really never reached the device.
final class FakeSoundbarProtocol: URLProtocol, @unchecked Sendable {
  /// Per-test device state. Installed as `current` before the client runs.
  final class Device: @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [(path: String, value: String)] = []

    var muted = false
    var volume = 30
    /// False models an endpoint the firmware does not answer, i.e. an unknown mute state.
    var muteEndpointExists = true

    func record(path: String, value: String) {
      lock.lock()
      _writes.append((path, value))
      lock.unlock()
    }

    var writes: [(path: String, value: String)] {
      lock.lock()
      defer { lock.unlock() }
      return _writes
    }

    func volumeWrites() -> [String] { writes.filter { $0.path == "player:volume" }.map(\.value) }
  }

  /// Boxed so the shared registry is a `let` (Swift 6 rejects mutable global state). Keyed by
  /// host because swift-testing runs tests in parallel and URLProtocol is process-global.
  private final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [String: Device] = [:]

    func install(_ device: Device, forHost host: String) {
      lock.lock()
      devices[host] = device
      lock.unlock()
    }

    func device(forHost host: String?) -> Device? {
      lock.lock()
      defer { lock.unlock() }
      guard let host else { return nil }
      return devices[host]
    }
  }

  private static let registry = Registry()

  static func install(_ device: Device, forHost host: String) {
    registry.install(device, forHost: host)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let path = components.queryItems?.first(where: { $0.name == "path" })?.value
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let device = Self.registry.device(forHost: url.host) ?? Device()

    if components.path == "/api/setData" {
      let value = components.queryItems?.first(where: { $0.name == "value" })?.value ?? ""
      device.record(path: path, value: value)
      respond(#"{"value":{"type":"null_"}}"#)
      return
    }

    switch path {
    case "settings:/mediaPlayer/mute":
      guard device.muteEndpointExists else {
        client?.urlProtocol(
          self,
          didReceive: HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
          )!,
          cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocolDidFinishLoading(self)
        return
      }
      respond(#"{"value":{"type":"bool_","bool_":\#(device.muted)}}"#)
    case "player:volume":
      respond(
        #"{"value":{"type":"i32_","i32_":\#(device.volume)},"edit":{"step":"1","min":"0","max":"100"}}"#
      )
    default: respond(#"{"value":{"type":"null_"}}"#)
    }
  }

  override func stopLoading() {}

  private func respond(_ json: String) {
    guard let url = request.url else { return }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
      cacheStoragePolicy: .notAllowed
    )
    client?.urlProtocol(self, didLoad: Data(json.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}

/// Stands in for the NSPanel-backed overlay so AppModel can run headless in tests.
@MainActor final class RecordingOverlay: VolumeOverlayPresenting {
  private(set) var presentations = 0
  var position: OverlayPosition = .center

  func show(_ update: (VolumeOverlayState) -> Void) {
    presentations += 1
    update(VolumeOverlayState())
  }
}

/// Stands in for `MusicPlayerController.shared`, whose initializer sends real Apple Events to the
/// user's Music.app. When those ran through `NSAppleScript` off the main thread, the reply wait
/// pumped the main run loop and stalled every MainActor `Task.sleep` in the test process; tests
/// must not depend on whatever Music.app is doing.
struct StubMusicPlayer: MusicPlayerControlling {
  func isRunning() -> Bool { false }
  func permissionStatus(askUserIfNeeded: Bool) -> MusicAutomationPermissionStatus {
    .musicNotRunning
  }
  func isPlaying() async -> Bool { false }
  @discardableResult func rewindToStart() async -> Bool { false }
}
