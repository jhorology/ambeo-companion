import CoreAudio
import Foundation
import KeyboardShortcuts
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

  @MainActor
  @Test(
    "Volume and mute shortcuts are disabled while Media Key Interception is on and enabled when off"
  ) func volumeShortcutsToggleWithMediaKeyInterception() {
    let suffix = UUID().uuidString
    let upName = KeyboardShortcuts.Name(
      "test-volumeUp-\(suffix)",
      initial: .init(.f17, modifiers: [.command, .option, .control, .shift])
    )
    let downName = KeyboardShortcuts.Name(
      "test-volumeDown-\(suffix)",
      initial: .init(.f18, modifiers: [.command, .option, .control, .shift])
    )
    let muteName = KeyboardShortcuts.Name(
      "test-toggleMute-\(suffix)",
      initial: .init(.f19, modifiers: [.command, .option, .control, .shift])
    )
    let names = MediaKeyCoordinator.VolumeShortcutNames(
      volumeUp: upName,
      volumeDown: downName,
      toggleMute: muteName
    )
    let coordinator = MediaKeyCoordinator(volumeShortcuts: names)
    defer {
      coordinator.stopKeyboardShortcuts()
      for name in names.all { KeyboardShortcuts.setShortcut(nil, for: name) }
    }

    // Initially Media Key Interception is ON -> volume shortcuts disabled
    coordinator.setupKeyboardShortcuts(
      volumeShortcutsEnabled: false,
      onToggleAmbeoMode: {},
      onCycleAmbeoLevel: {},
      onCyclePreset: {},
      onToggleNightMode: {},
      onToggleVoiceEnhancement: {},
      onWakeUpSoundbar: {}
    )
    #expect(!KeyboardShortcuts.isEnabled(for: upName))
    #expect(!KeyboardShortcuts.isEnabled(for: downName))
    #expect(!KeyboardShortcuts.isEnabled(for: muteName))

    // Turning Media Key Interception OFF enables all three shortcuts
    coordinator.setVolumeShortcutsEnabled(true)
    #expect(KeyboardShortcuts.isEnabled(for: upName))
    #expect(KeyboardShortcuts.isEnabled(for: downName))
    #expect(KeyboardShortcuts.isEnabled(for: muteName))

    // Turning Media Key Interception back ON disables them again
    coordinator.setVolumeShortcutsEnabled(false)
    #expect(!KeyboardShortcuts.isEnabled(for: upName))
    #expect(!KeyboardShortcuts.isEnabled(for: downName))
    #expect(!KeyboardShortcuts.isEnabled(for: muteName))
  }

  @MainActor @Test("AppModel volumeUp, volumeDown, and toggleMute drive soundbar and OSD")
  func appModelVolumeAndMuteActions() async {
    let device = FakeSoundbarProtocol.Device()
    device.volume = 30
    device.muted = false
    let host = "fake-ambeo-\(UUID().uuidString.prefix(8)).local"
    FakeSoundbarProtocol.install(device, forHost: host)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeSoundbarProtocol.self]
    let client = AmbeoClient(host: host, configuration: config)
    await client.register(AmbeoEndpoint.Player.Volume())
    await client.register(AmbeoEndpoint.Player.Mute())

    let overlay = RecordingOverlay()
    var settings = AppSettings()
    settings.mediaKeyEnabled = false
    let model = AppModel(
      settings: settings,
      autostart: false,
      volumeOverlay: overlay,
      musicPlayer: StubMusicPlayer()
    )
    model.ambeoClient = client

    await model.volumeUp()
    await model.volumeDown()
    await model.toggleMute()

    #expect(
      device.volumeWrites() == [#"{"type":"i32_","i32_":31}"#, #"{"type":"i32_","i32_":30}"#]
    )
    let muteWrites = device.writes.filter { $0.path == "settings:/mediaPlayer/mute" }.map(\.value)
    #expect(muteWrites == [#"{"type":"bool_","bool_":true}"#])
    #expect(overlay.presentations == 3)
  }

  @Test("LED brightness cycles 0 -> 25 -> 50 -> 100 -> 0 and snaps intermediate values upward")
  func ledBrightnessCycling() {
    #expect(SoundbarCommandController.nextLedBrightness(after: 0) == 25)
    #expect(SoundbarCommandController.nextLedBrightness(after: 25) == 50)
    #expect(SoundbarCommandController.nextLedBrightness(after: 50) == 100)
    #expect(SoundbarCommandController.nextLedBrightness(after: 100) == 0)
    // Intermediate values from the Smart Control slider advance to the next step
    #expect(SoundbarCommandController.nextLedBrightness(after: 10) == 25)
    #expect(SoundbarCommandController.nextLedBrightness(after: 37) == 50)
    #expect(SoundbarCommandController.nextLedBrightness(after: 80) == 100)
  }

  @MainActor
  @Test("AppModel cycles all LEDs together as well as individual LED brightness and Logo state")
  func appModelLedBrightnessActions() async {
    let device = FakeSoundbarProtocol.Device()
    device.ledBarBrightness = 50
    device.logoBrightness = 50
    device.logoLedEnabled = true
    device.codecLedBrightness = 50
    let host = "fake-ambeo-\(UUID().uuidString.prefix(8)).local"
    FakeSoundbarProtocol.install(device, forHost: host)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeSoundbarProtocol.self]
    let client = AmbeoClient(host: host, configuration: config)
    await client.register(AmbeoEndpoint.UI.LedBarBrightness())
    await client.register(AmbeoEndpoint.UI.AmbeoLogoBrightness())
    await client.register(AmbeoEndpoint.UI.AmbeoLogoState())
    await client.register(AmbeoEndpoint.UI.CodecLedBrightness())

    let overlay = RecordingOverlay()
    let model = AppModel(
      settings: AppSettings(),
      autostart: false,
      volumeOverlay: overlay,
      musicPlayer: StubMusicPlayer()
    )
    model.ambeoClient = client

    // 1. All LEDs: 50 -> 100
    await model.cycleAllLedsBrightness()
    #expect(overlay.lastState.ledOverlay == LedOverlayInfo(title: "ALL LEDS", brightness: 100))

    // 2. All LEDs: 100 -> 0 (also turns off settings:/popcorn/ui/ledStatus)
    await model.cycleAllLedsBrightness()
    #expect(overlay.lastState.ledOverlay == LedOverlayInfo(title: "ALL LEDS", brightness: 0))

    // 3. Individual AMBEO Logo: 0 (with ledStatus=false) -> 25 (re-enables ledStatus=true)
    await model.cycleAmbeoLogoBrightness()
    #expect(overlay.lastState.ledOverlay == LedOverlayInfo(title: "LOGO LED", brightness: 25))

    // 4. Individual LED Bar: 0 -> 25, Codec LED: 0 -> 25
    await model.cycleLedBarBrightness()
    #expect(overlay.lastState.ledOverlay == LedOverlayInfo(title: "LED BAR", brightness: 25))
    await model.cycleCodecLedBrightness()
    #expect(overlay.lastState.ledOverlay == LedOverlayInfo(title: "CODEC LED", brightness: 25))

    let logoStateWrites = device.writes.filter { $0.path == "settings:/popcorn/ui/ledStatus" }.map(
      \.value
    )
    #expect(
      logoStateWrites == [#"{"type":"bool_","bool_":false}"#, #"{"type":"bool_","bool_":true}"#]
    )
    #expect(overlay.presentations == 5)
  }

  @MainActor
  @Test(
    "Hardware LED brightness round-trip (all LEDs, 0% logo off, 25% logo re-enable, and full restore)",
    .enabled(
      if: ProcessInfo.processInfo.environment["AMBEO_INTEGRATION"] == "1",
      "Set AMBEO_INTEGRATION=1 to test the real soundbar"
    )
  ) func hardwareLedBrightnessRoundTrip() async throws {
    let host = "ambeo.local"
    let client = AmbeoClient(host: host)
    await SoundbarSession.registerAllEndpoints(on: client)

    let origBar = try #require(await client.getValue(for: AmbeoEndpoint.UI.LedBarBrightness()))
    let origCodec = try #require(await client.getValue(for: AmbeoEndpoint.UI.CodecLedBrightness()))
    let origLogo = try #require(await client.getValue(for: AmbeoEndpoint.UI.AmbeoLogoBrightness()))
    let origLogoState = try #require(await client.getValue(for: AmbeoEndpoint.UI.AmbeoLogoState()))

    func readFreshState() async -> AmbeoState {
      let reader = AmbeoClient(host: host)
      await reader.register(AmbeoEndpoint.UI.LedBarBrightness())
      await reader.register(AmbeoEndpoint.UI.CodecLedBrightness())
      await reader.register(AmbeoEndpoint.UI.AmbeoLogoBrightness())
      await reader.register(AmbeoEndpoint.UI.AmbeoLogoState())
      let state = await reader.state
      await reader.shutdown()
      return state
    }

    // Step 1: Set all LEDs to 100%, then cycle -> 0% (turns off AMBEO Logo state)
    _ = await SoundbarCommandController.setLedBarBrightness(100, client: client)
    let cycledZero = await SoundbarCommandController.cycleAllLedsBrightness(client: client)
    let afterZero = await readFreshState()

    // Step 2: Cycle from 0% -> 25% (must re-enable AMBEO Logo state AND set brightness to 25%)
    let cycled25 = await SoundbarCommandController.cycleAllLedsBrightness(client: client)
    let after25 = await readFreshState()

    // Always restore original hardware settings before asserting
    try? await client.set(
      AmbeoEndpoint.UI.AmbeoLogoState(),
      valueJSON: "{\"type\":\"bool_\",\"bool_\":\(origLogoState)}"
    )
    try? await client.set(
      AmbeoEndpoint.UI.AmbeoLogoBrightness(),
      valueJSON: "{\"type\":\"i32_\",\"i32_\":\(origLogo)}"
    )
    try? await client.set(
      AmbeoEndpoint.UI.LedBarBrightness(),
      valueJSON: "{\"type\":\"i32_\",\"i32_\":\(origBar)}"
    )
    try? await client.set(
      AmbeoEndpoint.UI.CodecLedBrightness(),
      valueJSON: "{\"type\":\"i32_\",\"i32_\":\(origCodec)}"
    )
    await client.shutdown()

    let restored = await readFreshState()

    #expect(cycledZero == 0)
    #expect(afterZero.ledBarBrightness == 0)
    #expect(afterZero.codecLedBrightness == 0)
    #expect(afterZero.isLogoLedEnabled == false)

    #expect(cycled25 == 25)
    #expect(after25.ledBarBrightness == 25)
    #expect(after25.codecLedBrightness == 25)
    #expect(after25.logoBrightness == 25)
    #expect(after25.isLogoLedEnabled == true)

    #expect(restored.ledBarBrightness == origBar)
    #expect(restored.codecLedBrightness == origCodec)
    #expect(restored.logoBrightness == origLogo)
    #expect(restored.isLogoLedEnabled == origLogoState)
  }
}
