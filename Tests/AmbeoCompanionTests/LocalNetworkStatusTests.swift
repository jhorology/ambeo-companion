import Foundation
import Testing

@testable import AmbeoCompanion
@testable import AmbeoCore

/// The inference the menu bar and the Permissions window show when macOS blocks local-network
/// access. It has to be driven by observable state, because elapsed time is not observable and a
/// silent browser produces no events at all.
@MainActor @Suite("Local Network Inference (app side)") struct LocalNetworkStatusTests {
  private func model() -> AppModel {
    AppModel(settings: AppSettings(), autostart: false, volumeOverlay: RecordingOverlay())
  }

  @Test("Nothing found yet, inside the grace window, is probing") func probing() {
    let model = model()
    #expect(model.localNetworkStatus == .probing)
  }

  @Test("Silence past the grace window reports nothing found") func graceElapsedWithoutResults() {
    let model = model()
    model.discoveryGraceElapsed = true
    #expect(model.localNetworkStatus == .nothingFound)
  }

  @Test("A discovered device proves browsing works, even without a client") func deviceAppears() {
    let model = model()
    model.discoveryGraceElapsed = true
    let device = SennheiserNetworkDevice(
      uuid: "ambeosoundbarmini-2ccbc823-81a7-494e-a9a8-decccfa345b4",
      serial: "000034826737",
      name: "サウンドバー",
      ip: "192.168.0.20"
    )
    model.networkDevices = [device]
    #expect(model.localNetworkStatus == .allowed)
  }

  @Test("A connected client counts even if the device list is empty") func clientConnected() async {
    let model = model()
    model.discoveryGraceElapsed = true
    let config = URLSessionConfiguration.ephemeral
    model.ambeoClient = AmbeoClient(host: "192.168.0.20", configuration: config)
    #expect(model.localNetworkStatus == .allowed)
    await model.ambeoClient?.shutdown()
  }
}
