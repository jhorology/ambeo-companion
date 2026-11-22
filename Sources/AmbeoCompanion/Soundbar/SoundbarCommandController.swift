import AmbeoCore
import Foundation
import Logging

/// Executes user-initiated remote control commands against `AmbeoClient` and holds pure helper
/// functions for preset/level cycling and OSD path eligibility.
@MainActor enum SoundbarCommandController {
  enum LedTarget: Sendable, Equatable {
    case all
    case ledBar
    case ambeoLogo
    case codecLed

    nonisolated var osdTitle: String {
      switch self {
      case .all: return "ALL LEDS"
      case .ledBar: return "LED BAR"
      case .ambeoLogo: return "LOGO LED"
      case .codecLed: return "CODEC LED"
      }
    }
  }

  // MARK: - Pure Helpers (Testable without a client)

  nonisolated static let ledBrightnessLevels: [Int] = [0, 25, 50, 100]

  nonisolated static func nextLedBrightness(after current: Int) -> Int {
    let clamped = max(0, current)
    return ledBrightnessLevels.first(where: { $0 > clamped }) ?? 0
  }

  nonisolated static func nextAmbeoLevel(after current: String) -> String {
    let levels = AmbeoEndpoint.Audio.AmbeoLevel.allLevels
    let normalized = current.lowercased()
    if let idx = levels.firstIndex(of: normalized) { return levels[(idx + 1) % levels.count] }
    return "standard"
  }

  nonisolated static func nextPreset(after current: String) -> String {
    let presets = AmbeoEndpoint.Audio.Preset.allPresets
    let normalized = current.lowercased()
    if let idx = presets.firstIndex(of: normalized) { return presets[(idx + 1) % presets.count] }
    return "adaptive"
  }

  nonisolated static func ledTarget(forPath path: String) -> LedTarget? {
    switch path {
    case AmbeoEndpoint.UI.LedBarBrightness().path: return .ledBar
    case AmbeoEndpoint.UI.AmbeoLogoBrightness().path, AmbeoEndpoint.UI.AmbeoLogoState().path:
      return .ambeoLogo
    case AmbeoEndpoint.UI.CodecLedBrightness().path: return .codecLed
    default: return nil
    }
  }

  nonisolated static func isOSDEligible(path: String, currentPreset: String) -> Bool {
    if ledTarget(forPath: path) != nil { return true }
    let activeAmbeoLevelPath =
      "settings:/popcorn/audio/audioPresets/ambeoModeLevel_\(currentPreset.lowercased())"
    let eligiblePaths: Set<String> = [
      AmbeoEndpoint.Player.Volume().path, AmbeoEndpoint.Player.Mute().path,
      AmbeoEndpoint.Audio.Preset().path, AmbeoEndpoint.Audio.AmbeoMode().path,
      AmbeoEndpoint.Audio.NightMode().path, AmbeoEndpoint.Audio.VoiceEnhancement().path,
      activeAmbeoLevelPath,
    ]
    return eligiblePaths.contains(path)
  }

  // MARK: - Media Key Volume & Mute Commands

  /// Toggles mute on the soundbar and returns the new mute state when successful.
  static func toggleMute(client: AmbeoClient) async -> Bool? {
    let isMuted = await client.state.isMuted
    let newMute = !isMuted
    do {
      try await client.set(
        AmbeoEndpoint.Player.Mute(),
        valueJSON: "{\"type\":\"bool_\",\"bool_\":\(newMute)}",
        timeout: AmbeoClient.interactiveTimeout
      )
      return newMute
    } catch {
      Logger.audio.warning("Media key: failed to set mute (\(error.localizedDescription))")
      return nil
    }
  }

  /// Steps the soundbar volume up or down and returns the new OSD gauge value (`0...1`) when successful.
  static func adjustVolume(direction: SystemEvent.MediaKey, client: AmbeoClient) async -> Double? {
    guard direction == .soundUp || direction == .soundDown else { return nil }
    guard let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume()) else { return nil }
    let current = await client.state.volume
    let step: Int = entry.edit.flatMap { $0.step } ?? VolumeAdjustment.defaultStep
    let minVol = entry.edit.flatMap { $0.min }
    let maxVol = entry.edit.flatMap { $0.max }
    let delta = direction == .soundUp ? step : -step
    let newVol = VolumeAdjustment.clamped(current + delta, min: minVol, max: maxVol)
    // Position within the device min...max range. AMBEO uses 0...100, so this matches the hardware step.
    let pct = VolumeAdjustment.gauge(value: newVol, min: minVol, max: maxVol)
    do {
      try await client.set(
        AmbeoEndpoint.Player.Volume(),
        valueJSON: "{\"type\":\"i32_\",\"i32_\":\(newVol)}"
      )
      return pct
    } catch {
      Logger.audio.warning("Media key: failed to set volume (\(error.localizedDescription))")
      return nil
    }
  }

  // MARK: - Soundbar Mode & Preset Commands

  static func toggleAmbeoMode(client: AmbeoClient) async -> Bool {
    let current = await client.state.isAmbeoMode
    let newMode = !current
    do {
      try await client.set(
        AmbeoEndpoint.Audio.AmbeoMode(),
        valueJSON: "{\"type\":\"bool_\",\"bool_\":\(newMode)}"
      )
      Logger.audio.info("AMBEO Mode -> \(newMode)")
      return true
    } catch {
      Logger.audio.warning("Failed to set AMBEO Mode (\(error.localizedDescription))")
      return false
    }
  }

  static func setAmbeoLevel(_ level: String, client: AmbeoClient) async -> Bool {
    let preset = await client.state.preset
    let endpoint = AmbeoEndpoint.Audio.AmbeoLevel(preset: preset)
    do {
      try await client.set(
        endpoint,
        valueJSON: "{\"type\":\"popcornAmbeoModeLevel\",\"popcornAmbeoModeLevel\":\"\(level)\"}"
      )
      Logger.audio.info("AMBEO Level (\(preset)) -> \(level)")
      return true
    } catch {
      Logger.audio.warning("Failed to set AMBEO Level (\(error.localizedDescription))")
      return false
    }
  }

  static func cycleAmbeoLevel(client: AmbeoClient) async -> Bool {
    let current = await client.state.ambeoLevel
    return await setAmbeoLevel(nextAmbeoLevel(after: current), client: client)
  }

  static func setPreset(_ preset: String, client: AmbeoClient) async -> Bool {
    do {
      try await client.set(
        AmbeoEndpoint.Audio.Preset(),
        valueJSON: "{\"type\":\"popcornAudioPreset\",\"popcornAudioPreset\":\"\(preset)\"}"
      )
      Logger.audio.info("Preset -> \(preset)")
      return true
    } catch {
      Logger.audio.warning("Failed to set Preset (\(error.localizedDescription))")
      return false
    }
  }

  static func cyclePreset(client: AmbeoClient) async -> Bool {
    let current = await client.state.preset
    return await setPreset(nextPreset(after: current), client: client)
  }

  static func toggleNightMode(client: AmbeoClient) async -> Bool {
    let current = await client.state.isNightMode
    let newNight = !current
    do {
      try await client.set(
        AmbeoEndpoint.Audio.NightMode(),
        valueJSON: "{\"type\":\"bool_\",\"bool_\":\(newNight)}"
      )
      Logger.audio.info("Night Mode -> \(newNight)")
      return true
    } catch {
      Logger.audio.warning("Failed to set Night Mode (\(error.localizedDescription))")
      return false
    }
  }

  static func toggleVoiceEnhancement(client: AmbeoClient) async -> Bool {
    let current = await client.state.isVoiceEnhancement
    let newVoice = !current
    do {
      try await client.set(
        AmbeoEndpoint.Audio.VoiceEnhancement(),
        valueJSON: "{\"type\":\"bool_\",\"bool_\":\(newVoice)}"
      )
      Logger.audio.info("Voice Enhancement -> \(newVoice)")
      return true
    } catch {
      Logger.audio.warning("Failed to set Voice Enhancement (\(error.localizedDescription))")
      return false
    }
  }

  static func syncAutoStandby(_ target: Int, client: AmbeoClient) async -> Bool {
    do {
      try await client.set(
        AmbeoEndpoint.System.MaxIdleTime(),
        valueJSON: "{\"type\":\"i32_\",\"i32_\":\(target)}"
      )
      Logger.lifecycle.info("Synced Auto Standby to soundbar: \(target) seconds")
      return true
    } catch {
      Logger.lifecycle.error(
        "Failed to sync Auto Standby to soundbar: \(error.localizedDescription)"
      )
      return false
    }
  }

  static func wakeUp(client: AmbeoClient) async -> Bool {
    do {
      try await client.activate(path: "ui:/inputs/hdmiTv")
      Logger.lifecycle.info("Shortcut: Soundbar awake requested (HDMI TV activated)")
      return true
    } catch {
      Logger.lifecycle.error("Failed to awake soundbar: \(error.localizedDescription)")
      return false
    }
  }

  // MARK: - LED Brightness Commands

  static func setLedBarBrightness(_ brightness: Int, client: AmbeoClient) async -> Bool {
    let clamped = VolumeAdjustment.clamped(brightness, min: 0, max: 100)
    do {
      try await client.set(
        AmbeoEndpoint.UI.LedBarBrightness(),
        valueJSON: "{\"type\":\"i32_\",\"i32_\":\(clamped)}"
      )
      Logger.audio.info("LED Bar Brightness -> \(clamped)%")
      return true
    } catch {
      Logger.audio.warning("Failed to set LED Bar Brightness (\(error.localizedDescription))")
      return false
    }
  }

  static func setCodecLedBrightness(_ brightness: Int, client: AmbeoClient) async -> Bool {
    let clamped = VolumeAdjustment.clamped(brightness, min: 0, max: 100)
    do {
      try await client.set(
        AmbeoEndpoint.UI.CodecLedBrightness(),
        valueJSON: "{\"type\":\"i32_\",\"i32_\":\(clamped)}"
      )
      Logger.audio.info("Codec LED Brightness -> \(clamped)%")
      return true
    } catch {
      Logger.audio.warning("Failed to set Codec LED Brightness (\(error.localizedDescription))")
      return false
    }
  }

  static func setAmbeoLogoBrightness(_ brightness: Int, client: AmbeoClient) async -> Bool {
    let clamped = VolumeAdjustment.clamped(brightness, min: 0, max: 100)
    if clamped == 0 {
      // AMBEO Logo has a dedicated on/off switch (`settings:/popcorn/ui/ledStatus`) in addition
      // to `ambeoSection/brightness`. Turning `ledStatus` off guarantees full extinction even on
      // firmware builds whose brightness slider minimum is > 0.
      try? await client.set(
        AmbeoEndpoint.UI.AmbeoLogoBrightness(),
        valueJSON: "{\"type\":\"i32_\",\"i32_\":0}"
      )
      do {
        try await client.set(
          AmbeoEndpoint.UI.AmbeoLogoState(),
          valueJSON: "{\"type\":\"bool_\",\"bool_\":false}"
        )
        Logger.audio.info("AMBEO Logo Brightness -> Off (0%)")
        return true
      } catch {
        Logger.audio.warning("Failed to turn off AMBEO Logo (\(error.localizedDescription))")
        return false
      }
    } else {
      do {
        try await client.set(
          AmbeoEndpoint.UI.AmbeoLogoBrightness(),
          valueJSON: "{\"type\":\"i32_\",\"i32_\":\(clamped)}"
        )
        if !(await client.state.isLogoLedEnabled) {
          try await client.set(
            AmbeoEndpoint.UI.AmbeoLogoState(),
            valueJSON: "{\"type\":\"bool_\",\"bool_\":true}"
          )
        }
        Logger.audio.info("AMBEO Logo Brightness -> \(clamped)%")
        return true
      } catch {
        Logger.audio.warning("Failed to set AMBEO Logo Brightness (\(error.localizedDescription))")
        return false
      }
    }
  }

  static func cycleLedBarBrightness(client: AmbeoClient) async -> Int? {
    let current = await client.state.ledBarBrightness
    let target = nextLedBrightness(after: current)
    return await setLedBarBrightness(target, client: client) ? target : nil
  }

  static func cycleCodecLedBrightness(client: AmbeoClient) async -> Int? {
    let current = await client.state.codecLedBrightness
    let target = nextLedBrightness(after: current)
    return await setCodecLedBrightness(target, client: client) ? target : nil
  }

  static func cycleAmbeoLogoBrightness(client: AmbeoClient) async -> Int? {
    let s = await client.state
    let current = s.isLogoLedEnabled ? s.logoBrightness : 0
    let target = nextLedBrightness(after: current)
    return await setAmbeoLogoBrightness(target, client: client) ? target : nil
  }

  static func cycleAllLedsBrightness(client: AmbeoClient) async -> Int? {
    let current = await client.state.ledBarBrightness
    let target = nextLedBrightness(after: current)
    async let barOk = setLedBarBrightness(target, client: client)
    async let logoOk = setAmbeoLogoBrightness(target, client: client)
    async let codecOk = setCodecLedBrightness(target, client: client)
    let results = await [barOk, logoOk, codecOk]
    return results.contains(true) ? target : nil
  }
}
