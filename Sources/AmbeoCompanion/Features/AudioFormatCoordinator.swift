import AmbeoCore
import CoreAudio
import Foundation
import Logging
import Observation

/// Observes CoreAudio output devices and physical formats, recovers changed HDMI/DisplayPort UIDs,
/// and enforces the user's configured stereo fallback format after Dolby Atmos passthrough ends.
@Observable @MainActor final class AudioFormatCoordinator {
  private(set) var currentAudioDevice: AudioDevice? = nil
  private(set) var availableAudioDevices: [AudioDevice] = []

  private var monitoringAudioDeviceTask: Task<Void, Never>?
  private var monitoringOutputDevicesTask: Task<Void, Never>?
  private var monitoringFormatTask: Task<Void, Never>?
  /// Device and output stream that `monitoringFormatTask` observes.
  private var monitoredFormatSource: (device: AudioDeviceID, stream: AudioStreamID)?

  // MARK: - Pure Helpers (Testable without CoreAudio hardware)

  /// Returns a recovered UID when the saved HDMI/DisplayPort UID changed its 8-hex suffix.
  nonisolated static func recoveredUID(currentUID: String, in devices: [AudioDevice]) -> String? {
    guard let device = AudioDeviceSelection.resolve(uid: currentUID, in: devices),
      device.uid != currentUID
    else { return nil }
    return device.uid
  }

  /// Auto-selects the best 2ch format closest to 48 kHz (preferring higher bit depth on ties).
  nonisolated static func bestFallbackFormat(
    from supportedFormats: [AudioPhysicalFormat]
  ) -> AudioPhysicalFormat? {
    supportedFormats.filter { $0.channels == 2 }.sorted {
      if $0.sampleRate != $1.sampleRate { return $0.distanceFrom48kHz < $1.distanceFrom48kHz }
      return $0.bitDepth > $1.bitDepth
    }.first
  }

  // MARK: - Monitoring

  func startMonitoring(
    targetUID: @escaping @MainActor () -> String,
    fallbackFormatID: @escaping @MainActor () -> String,
    onRecoveredUID: @escaping @MainActor (String) -> Void,
    onResetFormatObserver: @escaping @MainActor () -> Void,
    onFormatChange: @escaping @MainActor (AudioPhysicalFormat?, AudioDevice) async -> Void
  ) {
    monitoringAudioDeviceTask?.cancel()
    monitoringOutputDevicesTask?.cancel()

    monitoringOutputDevicesTask = Task { [weak self] in
      for await devices in AudioDeviceMonitor.shared.outputDevicesStream {
        guard !Task.isCancelled, let self else { return }
        self.availableAudioDevices = devices
        let currentUID = targetUID()
        if let recovered = Self.recoveredUID(currentUID: currentUID, in: devices) {
          Logger.audio.info("Recovered display output UID: \(currentUID) -> \(recovered)")
          onRecoveredUID(recovered)
        }
        self.updateFormatMonitoringForActiveDevice(
          targetUID: targetUID(),
          onResetFormatObserver: onResetFormatObserver,
          onFormatChange: onFormatChange
        )
      }
    }

    monitoringAudioDeviceTask = Task { [weak self] in
      for await device in AudioDeviceMonitor.shared.defaultDeviceStream {
        guard !Task.isCancelled, let self else { return }
        self.currentAudioDevice = device
        Logger.audio.debug("Default audio device changed: \(String(describing: device))")

        self.updateFormatMonitoringForActiveDevice(
          targetUID: targetUID(),
          onResetFormatObserver: onResetFormatObserver,
          onFormatChange: onFormatChange
        )

        let uid = targetUID()
        let fallbackID = fallbackFormatID()
        guard let curDev = device, curDev.uid == uid, !fallbackID.isEmpty else { continue }
        self.applyFallbackFormatIfNeeded(for: curDev, fallbackFormatID: fallbackID)
      }
    }
  }

  func updateFormatMonitoringForActiveDevice(
    targetUID: String,
    onResetFormatObserver: @escaping @MainActor () -> Void,
    onFormatChange: @escaping @MainActor (AudioPhysicalFormat?, AudioDevice) async -> Void
  ) {
    let targetDevice: AudioDevice?
    if !targetUID.isEmpty {
      targetDevice = AudioDeviceMonitor.shared.audioDevice(withUid: targetUID)
    } else {
      targetDevice = currentAudioDevice
    }

    guard let device = targetDevice else {
      stopMonitoringFormat(onResetFormatObserver: onResetFormatObserver)
      return
    }

    startMonitoringFormat(
      for: device,
      onResetFormatObserver: onResetFormatObserver,
      onFormatChange: onFormatChange
    )
  }

  private func startMonitoringFormat(
    for device: AudioDevice,
    onResetFormatObserver: @escaping @MainActor () -> Void,
    onFormatChange: @escaping @MainActor (AudioPhysicalFormat?, AudioDevice) async -> Void
  ) {
    // During Atmos passthrough, macOS briefly moves the default output to another device whenever
    // another app plays a sound. With a target device set, the source is unchanged, so keep the
    // existing stream instead of tearing it down on every switch.
    let streamID = AudioDeviceMonitor.shared.outputStreamID(for: device.id)
    if let source = monitoredFormatSource, let streamID, source.device == device.id,
      source.stream == streamID, monitoringFormatTask != nil
    {
      return
    }

    monitoringFormatTask?.cancel()
    monitoredFormatSource = streamID.map { (device: device.id, stream: $0) }
    onResetFormatObserver()
    monitoringFormatTask = Task {
      for await format in AudioDeviceMonitor.shared.formatStream(for: device.id) {
        Logger.audio.debug("Physical format changed: \(String(describing: format?.displayName))")
        await onFormatChange(format, device)
      }
    }
  }

  func stopMonitoringFormat(onResetFormatObserver: () -> Void) {
    monitoringFormatTask?.cancel()
    monitoringFormatTask = nil
    monitoredFormatSource = nil
    onResetFormatObserver()
  }

  func stopMonitoring(onResetFormatObserver: () -> Void) {
    monitoringAudioDeviceTask?.cancel()
    monitoringAudioDeviceTask = nil
    monitoringOutputDevicesTask?.cancel()
    monitoringOutputDevicesTask = nil
    stopMonitoringFormat(onResetFormatObserver: onResetFormatObserver)
  }

  func applyFallbackFormatIfNeeded(for device: AudioDevice, fallbackFormatID: String) {
    guard !fallbackFormatID.isEmpty else { return }
    let formats = AudioDeviceMonitor.shared.supportedFormats(for: device.id)
    guard let format = formats.first(where: { $0.id == fallbackFormatID }) else { return }
    let current = AudioDeviceMonitor.shared.currentPhysicalFormat(for: device.id)
    guard let current, !current.isAtmosOrMultichannel else { return }
    if current.id != format.id {
      AudioDeviceMonitor.shared.fallback(format: format, for: device.id)
      Logger.audio.info("Applied fallback format: \(format.displayName)")
    }
  }
}
