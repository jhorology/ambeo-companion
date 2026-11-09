import AmbeoCore
import Foundation

/// AppModel presents the OSD through this protocol so tests can record presentations instead of
/// opening a real NSPanel. `VolumeOverlayManager` is the production implementation.
@MainActor protocol VolumeOverlayPresenting: AnyObject {
  /// Applied on the next `show`.
  var position: OverlayPosition { get set }
  func show(_ update: (VolumeOverlayState) -> Void)
}

extension VolumeOverlayPresenting {
  /// Synchronizes full soundbar state to the OSD overlay and presents it.
  func syncAndShow(
    from client: AmbeoClient?,
    isAtmosActive: Bool,
    explicitVolume: Double? = nil,
    explicitMute: Bool? = nil
  ) async {
    guard let client else {
      show { state in
        if let explicitVolume { state.volume = explicitVolume }
        if let explicitMute { state.isMuted = explicitMute }
        state.isAtmos = isAtmosActive
      }
      return
    }

    let s = await client.state
    // AMBEO reports volume as an absolute 0...100 count. The overlay gauge expects 0...1.
    let volPct = explicitVolume ?? (Double(s.volume) / 100.0)
    let muteState = explicitMute ?? s.isMuted

    show { state in
      state.volume = volPct
      state.isMuted = muteState
      state.isAmbeoMode = s.isAmbeoMode
      state.ambeoLevel = s.ambeoLevel
      state.isNightMode = s.isNightMode
      state.isVoiceEnhancement = s.isVoiceEnhancement
      state.isEcoMode = s.isEcoMode
      state.maxIdleTime = s.maxIdleTime
      state.powerTarget = s.powerTarget
      state.audioPreset = s.preset
      state.isAtmos = isAtmosActive
    }
  }
}

extension VolumeOverlayManager: VolumeOverlayPresenting {}
