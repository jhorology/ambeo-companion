import CoreAudio
import Foundation
import Testing

@testable import AmbeoCompanion
@testable import AmbeoCore

@Suite("Coordinators & Command Helpers") struct CoordinatorHelperTests {
  @Test("AMBEO Level cycles light -> standard -> boost -> light and defaults unknown to standard")
  func ambeoLevelCycling() {
    #expect(SoundbarCommandController.nextAmbeoLevel(after: "light") == "standard")
    #expect(SoundbarCommandController.nextAmbeoLevel(after: "standard") == "boost")
    #expect(SoundbarCommandController.nextAmbeoLevel(after: "boost") == "light")
    #expect(SoundbarCommandController.nextAmbeoLevel(after: "STANDARD") == "boost")
    #expect(SoundbarCommandController.nextAmbeoLevel(after: "unknown") == "standard")
  }

  @Test("Audio Preset cycles through all presets and defaults unknown to adaptive")
  func presetCycling() {
    let presets = AmbeoEndpoint.Audio.Preset.allPresets
    for (idx, preset) in presets.enumerated() {
      let expected = presets[(idx + 1) % presets.count]
      #expect(SoundbarCommandController.nextPreset(after: preset) == expected)
    }
    #expect(SoundbarCommandController.nextPreset(after: "unknown") == "adaptive")
  }

  @Test("OSD eligibility matches user-facing audio endpoints and only the active preset's level")
  func osdEligibility() {
    #expect(
      SoundbarCommandController.isOSDEligible(
        path: AmbeoEndpoint.Player.Volume().path,
        currentPreset: "music"
      )
    )
    #expect(
      SoundbarCommandController.isOSDEligible(
        path: "settings:/popcorn/audio/audioPresets/ambeoModeLevel_music",
        currentPreset: "Music"
      )
    )
    #expect(
      !SoundbarCommandController.isOSDEligible(
        path: "settings:/popcorn/audio/audioPresets/ambeoModeLevel_movie",
        currentPreset: "music"
      )
    )
    #expect(
      !SoundbarCommandController.isOSDEligible(
        path: AmbeoEndpoint.Audio.DecoderAudioFormat().path,
        currentPreset: "music"
      )
    )
  }

  @Test("Fallback format selection picks 2ch closest to 48kHz with highest bit depth")
  func bestFallbackFormat() {
    let f192 = AudioPhysicalFormat(channels: 2, bitDepth: 24, sampleRate: 192000)
    let f48_16 = AudioPhysicalFormat(channels: 2, bitDepth: 16, sampleRate: 48000)
    let f48_24 = AudioPhysicalFormat(channels: 2, bitDepth: 24, sampleRate: 48000)
    let f8ch = AudioPhysicalFormat(channels: 8, bitDepth: 24, sampleRate: 48000)

    let best = AudioFormatCoordinator.bestFallbackFormat(from: [f192, f48_16, f48_24, f8ch])
    #expect(best == f48_24)
  }

  @Test("Media key interception checks key-down, hooked keys, and default or hogged device")
  func mediaKeyInterceptionDecision() {
    let soundUpDown = SystemEvent(type: .media(.soundUp), isDown: true, modifiers: [], rawData1: 0)
    let soundUpRelease = SystemEvent(
      type: .media(.soundUp),
      isDown: false,
      modifiers: [],
      rawData1: 0
    )
    let playKey = SystemEvent(type: .media(.play), isDown: true, modifiers: [], rawData1: 0)

    // Matching default device -> intercept
    #expect(
      MediaKeyCoordinator.shouldIntercept(
        event: soundUpDown,
        targetDeviceUid: "hdmi-1",
        targetDeviceExists: true,
        defaultDeviceUid: "hdmi-1",
        isTargetHogged: false
      )
    )

    // Key release -> ignore
    #expect(
      !MediaKeyCoordinator.shouldIntercept(
        event: soundUpRelease,
        targetDeviceUid: "hdmi-1",
        targetDeviceExists: true,
        defaultDeviceUid: "hdmi-1",
        isTargetHogged: false
      )
    )

    // Unhooked media key -> ignore
    #expect(
      !MediaKeyCoordinator.shouldIntercept(
        event: playKey,
        targetDeviceUid: "hdmi-1",
        targetDeviceExists: true,
        defaultDeviceUid: "hdmi-1",
        isTargetHogged: false
      )
    )

    // Different default device, but target is hogged (Atmos passthrough) -> intercept
    #expect(
      MediaKeyCoordinator.shouldIntercept(
        event: soundUpDown,
        targetDeviceUid: "hdmi-1",
        targetDeviceExists: true,
        defaultDeviceUid: "speakers",
        isTargetHogged: true
      )
    )

    // Different default device and not hogged -> ignore
    #expect(
      !MediaKeyCoordinator.shouldIntercept(
        event: soundUpDown,
        targetDeviceUid: "hdmi-1",
        targetDeviceExists: true,
        defaultDeviceUid: "speakers",
        isTargetHogged: false
      )
    )
  }

  @MainActor @Test("AppSettingsStore persists and loads settings") func appSettingsStoreRoundTrip()
  {
    let suiteName = "io.github.jhorology.AmbeoCompanion.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = AppSettingsStore(defaults: defaults, storageKey: "settings")
    var settings = AppSettings()
    settings.ambeoUid = "ambeo-123"
    settings.atmosBoostAmount = 15
    settings.stealthRewindEnabled = true

    store.flushAndSaveNow(settings)
    let loaded = store.load()
    #expect(loaded == settings)
  }
}
