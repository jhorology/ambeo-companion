import Foundation
import Testing

@testable import AmbeoCompanion

@MainActor @Suite("App Target Structure") struct AppTargetStructureTests {
  @Test("AppModel runs headless when services are not started") func headlessConstruction() {
    // The test seam: no mDNS browsing, no CoreAudio subscriptions, no event taps, no global
    // shortcuts. Everything below is what the app does before any service touches the system.
    var settings = AppSettings()
    settings.atmosBoostAmount = 5
    let model = AppModel(settings: settings, autostart: false, volumeOverlay: RecordingOverlay())

    #expect(model.settings.atmosBoostAmount == 5)
    #expect(model.ambeoClient == nil)
    #expect(model.networkDevices.isEmpty)
    #expect(model.discoveryStartedAt == nil)
    #expect(model.soundbarState == nil)
  }

  @Test("The overlay is reached through a protocol so tests can record presentations")
  func overlaySeam() {
    let overlay = RecordingOverlay()
    let model = AppModel(settings: AppSettings(), autostart: false, volumeOverlay: overlay)
    model.volumeOverlay.show { state in
      state.volume = 0.5
      state.isMuted = true
    }
    #expect(overlay.presentations == 1)
    let productionOverlay: any VolumeOverlayPresenting = VolumeOverlayManager()
    #expect(productionOverlay is VolumeOverlayManager)
  }

  @Test("Bundle id has a development fallback outside a bundle") func bundleIdentifier() {
    #expect(!Bundle.id.isEmpty)
  }
}
