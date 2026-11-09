import Foundation
import Testing

@testable import AmbeoCompanion

@MainActor @Suite("OSD Position Setting") struct OverlayPositionTests {
  @Test("The position round-trips and older or unknown values fall back to center") func decoding()
    throws
  {
    var settings = AppSettings()
    settings.overlayPosition = .topRight
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(AppSettings.self, from: data).overlayPosition == .topRight)

    // Settings saved before the option existed.
    let legacy = Data(#"{"atmosBoostAmount":5}"#.utf8)
    let decodedLegacy = try JSONDecoder().decode(AppSettings.self, from: legacy)
    #expect(decodedLegacy.overlayPosition == .center)
    #expect(decodedLegacy.atmosBoostAmount == 5)

    // A value from a newer build must not reset the rest of the settings.
    let future = Data(#"{"overlayPosition":"bottomLeft","atmosBoostAmount":7}"#.utf8)
    let decodedFuture = try JSONDecoder().decode(AppSettings.self, from: future)
    #expect(decodedFuture.overlayPosition == .center)
    #expect(decodedFuture.atmosBoostAmount == 7)
  }

  @Test("AppModel hands the saved position to the overlay and follows later changes")
  func appModelForwardsPosition() {
    var settings = AppSettings()
    settings.overlayPosition = .topCenter
    let overlay = RecordingOverlay()
    let model = AppModel(
      settings: settings,
      autostart: false,
      volumeOverlay: overlay,
      musicPlayer: StubMusicPlayer()
    )
    #expect(overlay.position == .topCenter)

    model.settings.overlayPosition = .topRight
    #expect(overlay.position == .topRight)
  }
}
