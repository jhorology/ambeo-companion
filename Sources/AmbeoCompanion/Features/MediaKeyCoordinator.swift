import AmbeoCore
import Foundation
import KeyboardShortcuts
import Logging

extension KeyboardShortcuts.Name {
  static let toggleAmbeoMode = Self("toggleAmbeoMode")
  static let cycleAmbeoLevel = Self("cycleAmbeoLevel")
  static let cyclePreset = Self("cyclePreset")
  static let toggleNightMode = Self("toggleNightMode")
  static let toggleVoiceEnhancement = Self("toggleVoiceEnhancement")
  static let wakeUpSoundbar = Self("wakeUpSoundbar")
}

/// Manages media key interception via `SystemEventMonitor` and global keyboard shortcut bindings.
@MainActor final class MediaKeyCoordinator {
  nonisolated static let defaultHookedKeys: [SystemEvent.MediaKey] = [.soundUp, .soundDown, .mute]

  let hookedKeys: [SystemEvent.MediaKey]
  private var monitoringSystemEventTask: Task<Void, Never>?

  init(hookedKeys: [SystemEvent.MediaKey] = MediaKeyCoordinator.defaultHookedKeys) {
    self.hookedKeys = hookedKeys
  }

  /// Pure interception decision for media key events so it can be unit-tested without CoreAudio or CGEventTap.
  nonisolated static func shouldIntercept(
    event: SystemEvent,
    hookedKeys: [SystemEvent.MediaKey] = defaultHookedKeys,
    targetDeviceUid: String,
    targetDeviceExists: Bool,
    defaultDeviceUid: String?,
    isTargetHogged: @autoclosure () -> Bool
  ) -> Bool {
    guard event.isDown, case .media(let key) = event.type, hookedKeys.contains(key),
      !targetDeviceUid.isEmpty, targetDeviceExists
    else { return false }

    if defaultDeviceUid == targetDeviceUid { return true }
    if isTargetHogged() {
      Logger.audio.debug("Target device: [uid=\(targetDeviceUid)] is hogged, intercepting.")
      return true
    }
    return false
  }

  func startMonitoring(
    isShuttingDown: Bool,
    mediaKeyEnabled: Bool,
    mediaKeysGranted: Bool,
    audioDeviceUid: String,
    onMediaKey: @escaping @MainActor (SystemEvent.MediaKey) async -> Void,
    onStreamEnded: @escaping @MainActor () async -> Void
  ) {
    stopMonitoring()
    guard !isShuttingDown, mediaKeyEnabled, mediaKeysGranted else { return }

    let hookedKeys = self.hookedKeys
    monitoringSystemEventTask = Task {
      let stream = SystemEventMonitor.events(shouldIntercept: { ev in
        guard !audioDeviceUid.isEmpty,
          let device = AudioDeviceMonitor.shared.audioDevice(withUid: audioDeviceUid)
        else { return false }
        return Self.shouldIntercept(
          event: ev,
          hookedKeys: hookedKeys,
          targetDeviceUid: audioDeviceUid,
          targetDeviceExists: true,
          defaultDeviceUid: AudioDeviceMonitor.shared.currentDefaultDevice?.uid,
          isTargetHogged: AudioDeviceMonitor.shared.checkHogged(for: device.id)
        )
      })

      for await event in stream {
        guard case .media(let key) = event.type else { continue }
        Logger.lifecycle.debug("Intercepted media key: \(String(describing: key))")
        await onMediaKey(key)
      }
      // The stream ends when Accessibility is revoked (SystemEventMonitor polls AXIsProcessTrusted
      // on its own thread), so this is the event-driven permission check.
      guard !Task.isCancelled else { return }
      Logger.lifecycle.info("Media key stream ended; refreshing permission state.")
      await onStreamEnded()
    }
  }

  func stopMonitoring() {
    monitoringSystemEventTask?.cancel()
    monitoringSystemEventTask = nil
  }

  func setupKeyboardShortcuts(
    onToggleAmbeoMode: @escaping @MainActor () async -> Void,
    onCycleAmbeoLevel: @escaping @MainActor () async -> Void,
    onCyclePreset: @escaping @MainActor () async -> Void,
    onToggleNightMode: @escaping @MainActor () async -> Void,
    onToggleVoiceEnhancement: @escaping @MainActor () async -> Void,
    onWakeUpSoundbar: @escaping @MainActor () async -> Void
  ) {
    KeyboardShortcuts.onKeyDown(for: .toggleAmbeoMode) {
      Task { @MainActor in await onToggleAmbeoMode() }
    }
    KeyboardShortcuts.onKeyDown(for: .cycleAmbeoLevel) {
      Task { @MainActor in await onCycleAmbeoLevel() }
    }
    KeyboardShortcuts.onKeyDown(for: .cyclePreset) { Task { @MainActor in await onCyclePreset() } }
    KeyboardShortcuts.onKeyDown(for: .toggleNightMode) {
      Task { @MainActor in await onToggleNightMode() }
    }
    KeyboardShortcuts.onKeyDown(for: .toggleVoiceEnhancement) {
      Task { @MainActor in await onToggleVoiceEnhancement() }
    }
    KeyboardShortcuts.onKeyDown(for: .wakeUpSoundbar) {
      Task { @MainActor in await onWakeUpSoundbar() }
    }
  }
}
