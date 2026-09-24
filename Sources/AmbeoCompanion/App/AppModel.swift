import AmbeoCore
import AppKit
import Foundation
import KeyboardShortcuts
import Logging
import ServiceManagement
import SwiftUI

struct AppSettings: Codable {
  var ambeoUid: String = ""
  var audioDeviceUid: String = ""
  /// Stored as the format's `displayName` (which equals its `id`)
  var fallbackAudioFormatID: String = ""
  var mediaKeyEnabled: Bool = true
  var atmosBoostAmount: Double = 0
  var autoStandbySeconds: Int = 0

  enum CodingKeys: String, CodingKey {
    case ambeoUid, audioDeviceUid, fallbackAudioFormatID, mediaKeyEnabled, atmosBoostAmount,
      autoStandbySeconds
  }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ambeoUid = try container.decodeIfPresent(String.self, forKey: .ambeoUid) ?? ""
    audioDeviceUid = try container.decodeIfPresent(String.self, forKey: .audioDeviceUid) ?? ""
    fallbackAudioFormatID =
      try container.decodeIfPresent(String.self, forKey: .fallbackAudioFormatID) ?? ""
    mediaKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .mediaKeyEnabled) ?? true
    atmosBoostAmount = try container.decodeIfPresent(Double.self, forKey: .atmosBoostAmount) ?? 0
    autoStandbySeconds = try container.decodeIfPresent(Int.self, forKey: .autoStandbySeconds) ?? 0
  }
}

@Observable
@MainActor
final class AppModel: Sendable {
  private let storageKey = "\(Bundle.id).Setting"
  private let hookedKeys: [SystemEvent.MediaKey] = [.soundUp, .soundDown, .mute]

  private var saveTask: Task<Void, Never>?
  private var discoveringAmbeoTask: Task<Void, Never>?
  private var monitoringAudioDeviceTask: Task<Void, Never>?
  private var monitoringFormatTask: Task<Void, Never>?
  private var monitoringSystemEventTask: Task<Void, Never>?
  private var clientTask: Task<Void, Never>?
  private var clientGeneration = 0

  private var isCoreAudioAtmos: Bool = false
  private var isSoundbarAtmos: Bool = false
  private(set) var isAtmosActive: Bool = false
  private var appliedAtmosBoost: Int = 0
  private var atmosDeactivationTask: Task<Void, Never>?
  private var atmosTransitionTask: Task<Void, Never>?
  private var lastOSDTask: Task<Void, Never>?

  var settings: AppSettings {
    didSet {
      debouncedSaveSettings()
      if settings.ambeoUid != oldValue.ambeoUid {
        reconnectAmbeoClient()
      }
      if settings.audioDeviceUid != oldValue.audioDeviceUid {
        startMonitoringAudioDevice()
        restartSystemEventMonitorIfNeeded()
      }
      if settings.mediaKeyEnabled != oldValue.mediaKeyEnabled {
        restartSystemEventMonitorIfNeeded()
      }
      if settings.atmosBoostAmount != oldValue.atmosBoostAmount {
        handleAtmosBoostAmountChanged(
          from: oldValue.atmosBoostAmount,
          to: settings.atmosBoostAmount
        )
      }
      if settings.autoStandbySeconds != oldValue.autoStandbySeconds,
        settings.autoStandbySeconds != maxIdleTime
      {
        Task { [weak self] in
          await self?.syncAutoStandbyToSoundbar()
        }
      }
    }
  }

  private(set) var networkDevices: [SennheiserNetworkDevice] = []
  private(set) var currentAudioDevice: AudioDevice? = nil
  private(set) var ambeoClient: AmbeoClient? = nil
  private(set) var maxIdleTime: Int = 0

  private var lastAudioPreset: String? = nil

  let volumeOverlay = VolumeOverlayManager()
  var launchAtLoginState: Bool = false

  var isLaunchAtLoginEnabled: Bool {
    get {
      launchAtLoginState
    }
    set {
      launchAtLoginState = newValue
      setLaunchAtLogin(enabled: newValue)
    }
  }

  init() {
    if let data = UserDefaults.standard.data(forKey: storageKey),
      let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
    {
      settings = decoded
    } else {
      settings = AppSettings()
    }
    checkLaunchAtLoginStatus()
    startDiscoveringAmbeo()
    startMonitoringAudioDevice()
    if settings.mediaKeyEnabled {
      startMonitoringSystemEvent()
    }
    setupNotifications()
    setupKeyboardShortcuts()
  }

  // MARK: - Launch at Login

  func checkLaunchAtLoginStatus() {
    if #available(macOS 13.0, *) {
      launchAtLoginState = (SMAppService.mainApp.status == .enabled)
    }
  }

  func setLaunchAtLogin(enabled: Bool) {
    if #available(macOS 13.0, *) {
      do {
        if enabled {
          if SMAppService.mainApp.status != .enabled {
            try SMAppService.mainApp.register()
            Logger.lifecycle.info("SMAppService: Registered mainApp for launch at login.")
          }
        } else {
          if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
            Logger.lifecycle.info("SMAppService: Unregistered mainApp from launch at login.")
          }
        }
        checkLaunchAtLoginStatus()
      } catch {
        Logger.lifecycle.warning(
          "SMAppService: Launch at Login update failed (\(error.localizedDescription))."
        )
        checkLaunchAtLoginStatus()
      }
    }
  }

  // MARK: - AmbeoClient (State Manager)

  private func reconnectAmbeoClient() {
    clientGeneration += 1
    let generation = clientGeneration

    clientTask?.cancel()
    atmosDeactivationTask?.cancel()
    atmosDeactivationTask = nil
    atmosTransitionTask?.cancel()
    atmosTransitionTask = nil

    let previousClient = ambeoClient
    ambeoClient = nil

    // Preserve boost state across reconnections to prevent double-boosting.
    // If a boost was already applied to the soundbar hardware, resetting appliedAtmosBoost to 0
    // would cause the re-established client to apply another boost on top (+25% twice).
    isAtmosActive = appliedAtmosBoost > 0
    isCoreAudioAtmos = false
    isSoundbarAtmos = false

    let uid = settings.ambeoUid
    let host = networkDevices.first(where: { $0.uuid == uid })?.ip

    clientTask = Task {
      await previousClient?.stopObserving()
      guard !Task.isCancelled, generation == self.clientGeneration else { return }
      guard !uid.isEmpty, let host else { return }

      let client = AmbeoClient(host: host)
      self.ambeoClient = client

      await withTaskGroup(of: Void.self) { group in
        group.addTask { await client.register(AmbeoEndpoint.Player.Volume()) }
        group.addTask { await client.register(AmbeoEndpoint.Player.Mute()) }
        group.addTask { await client.register(AmbeoEndpoint.Audio.Preset()) }
        group.addTask { await client.register(AmbeoEndpoint.Audio.AmbeoMode()) }
        for preset in AmbeoEndpoint.Audio.Preset.allPresets {
          group.addTask { await client.register(AmbeoEndpoint.Audio.AmbeoLevel(preset: preset)) }
        }
        group.addTask { await client.register(AmbeoEndpoint.Audio.NightMode()) }
        group.addTask { await client.register(AmbeoEndpoint.Audio.VoiceEnhancement()) }
        group.addTask { await client.register(AmbeoEndpoint.Audio.EcoMode()) }
        group.addTask { await client.register(AmbeoEndpoint.System.MaxIdleTime()) }
        group.addTask { await client.register(AmbeoEndpoint.System.Power()) }
        group.addTask { await client.register(AmbeoEndpoint.Audio.DecoderAudioFormat()) }
      }

      guard !Task.isCancelled, generation == self.clientGeneration else {
        await client.stopObserving()
        return
      }

      await client.startObserving()
      await client.markInitialSyncCompleted()

      guard !Task.isCancelled, generation == self.clientGeneration else {
        await client.stopObserving()
        return
      }

      let initialSoundbarAtmos = await client.state.audioFormat?.isAtmos == true
      let initialMaxIdleTime = await client.state.maxIdleTime
      guard generation == self.clientGeneration else { return }
      if initialMaxIdleTime != self.settings.autoStandbySeconds {
        Logger.lifecycle.info(
          "Auto Standby mismatch detected (soundbar: \(initialMaxIdleTime)s, app setting: \(self.settings.autoStandbySeconds)s). Enforcing app setting."
        )
        await self.syncAutoStandbyToSoundbar()
      } else {
        self.maxIdleTime = initialMaxIdleTime
      }
      self.evaluateAtmosState(soundbarAtmos: initialSoundbarAtmos)
    }
  }

  // MARK: - Discovery

  private func startDiscoveringAmbeo() {
    discoveringAmbeoTask?.cancel()
    discoveringAmbeoTask = Task {
      for await devices in SennheiserDiscovery.browse() {
        self.networkDevices = devices
        Logger.network.debug("Discovered devices updated: \(devices.count) devices")
        // Reconnect if selected device just appeared on the network
        if self.ambeoClient == nil,
          !self.settings.ambeoUid.isEmpty,
          devices.contains(where: { $0.uuid == self.settings.ambeoUid })
        {
          self.reconnectAmbeoClient()
        }
      }
    }
  }

  // MARK: - Audio Device Monitoring (Format & Fallback)

  private func startMonitoringAudioDevice() {
    monitoringAudioDeviceTask?.cancel()
    monitoringAudioDeviceTask = Task {
      for await device in AudioDeviceMonitor.shared.defaultDeviceStream {
        self.currentAudioDevice = device
        Logger.audio.debug("Default audio device changed: \(String(describing: device))")

        self.updateFormatMonitoringForActiveDevice()

        guard let curDev = device,
          curDev.uid == self.settings.audioDeviceUid,
          !self.settings.fallbackAudioFormatID.isEmpty
        else { continue }

        self.applyFallbackFormatIfNeeded(for: curDev)
      }
    }
  }

  private func updateFormatMonitoringForActiveDevice() {
    let targetDevice: AudioDevice?
    if !settings.audioDeviceUid.isEmpty {
      targetDevice = AudioDeviceMonitor.shared.audioDevice(withUid: settings.audioDeviceUid)
    } else {
      targetDevice = currentAudioDevice
    }

    guard let device = targetDevice else {
      monitoringFormatTask?.cancel()
      monitoringFormatTask = nil
      return
    }

    startMonitoringFormat(for: device)
  }

  private func startMonitoringFormat(for device: AudioDevice) {
    monitoringFormatTask?.cancel()
    monitoringFormatTask = Task {
      for await format in AudioDeviceMonitor.shared.formatStream(for: device.id) {
        Logger.audio.debug("Physical format changed: \(String(describing: format?.displayName))")
        await self.handleAudioFormatChange(format, for: device)
      }
    }
  }

  private func handleAudioFormatChange(
    _ format: AudioPhysicalFormat?,
    for device: AudioDevice
  ) async {
    let wasAtmos = self.isCoreAudioAtmos
    let isAtmos = format?.isAtmosOrMultichannel == true

    Logger.audio.info(
      "Audio format on [\(device.name)]: \(format?.displayName ?? "unknown") (formatID=\(format?.formatID ?? 0) '\(format?.fourCCString ?? "")', isAtmosOrMultichannel=\(isAtmos))"
    )

    self.evaluateAtmosState(coreAudioAtmos: isAtmos)

    // If switching from Atmos/multichannel back to stereo, enforce fallback format
    if wasAtmos && !isAtmos {
      self.applyFallbackFormatIfNeeded(for: device)
    }
  }

  private func applyFallbackFormatIfNeeded(for device: AudioDevice) {
    guard !settings.fallbackAudioFormatID.isEmpty else { return }
    let formats = AudioDeviceMonitor.shared.supportedFormats(for: device.id)
    guard let format = formats.first(where: { $0.id == settings.fallbackAudioFormatID }) else {
      return
    }
    let current = AudioDeviceMonitor.shared.currentPhysicalFormat(for: device.id)
    if current?.id != format.id {
      AudioDeviceMonitor.shared.fallback(format: format, for: device.id)
      Logger.audio.info("Applied fallback format: \(format.displayName)")
    }
  }

  // MARK: - System Event Monitoring (Media Keys)

  private func restartSystemEventMonitorIfNeeded() {
    monitoringSystemEventTask?.cancel()
    monitoringSystemEventTask = nil
    if settings.mediaKeyEnabled {
      startMonitoringSystemEvent()
    }
  }

  func startMonitoringSystemEvent() {
    monitoringSystemEventTask?.cancel()

    // Capture current values so the Sendable closure doesn't need to touch self
    let audioDeviceUid = settings.audioDeviceUid
    let hookedKeys = self.hookedKeys

    monitoringSystemEventTask = Task {
      let stream = SystemEventMonitor.events(shouldIntercept: { ev in
        guard ev.isDown,
          case .media(let key) = ev.type,
          hookedKeys.contains(key),
          !audioDeviceUid.isEmpty,
          let device = AudioDeviceMonitor.shared.audioDevice(withUid: audioDeviceUid)
        else { return false }

        if let curDev = AudioDeviceMonitor.shared.currentDefaultDevice,
          curDev.uid == audioDeviceUid
        {
          return true
        }
        if AudioDeviceMonitor.shared.checkHogged(for: device.id) {
          Logger.audio.debug("Target device: [uid=\(audioDeviceUid)] is hogged, intercepting.")
          return true
        }
        return false
      })

      for await event in stream {
        guard case .media(let key) = event.type else { continue }
        Logger.lifecycle.debug("Intercepted media key: \(String(describing: key))")
        await self.handleMediaKey(key)
      }
    }
  }

  // MARK: - Volume Control & OSD (State-Manager Synced)

  /// Synchronizes full soundbar state to OSD overlay and presents it.
  private func syncAndShowOverlay(explicitVolume: Double? = nil, explicitMute: Bool? = nil) async {
    guard let client = ambeoClient else {
      volumeOverlay.show { state in
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

    volumeOverlay.show { state in
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

  private func handleMediaKey(_ key: SystemEvent.MediaKey) async {
    guard let client = ambeoClient else { return }

    switch key {
    case .mute:
      let isMuted = await client.state.isMuted
      let newMute = !isMuted
      do {
        try await client.set(
          AmbeoEndpoint.Player.Mute(),
          valueJSON: "{\"type\":\"bool_\",\"bool_\":\(newMute)}"
        )
      } catch {
        Logger.audio.warning("Media key: failed to set mute (\(error.localizedDescription))")
        return
      }
      await syncAndShowOverlay(explicitMute: newMute)

    case .soundUp, .soundDown:
      guard let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume()) else { return }
      let current = await client.state.volume
      let step: Int = entry.edit.flatMap { $0.step } ?? 1
      let minVol: Int = entry.edit.flatMap { $0.min } ?? 0
      let maxVol: Int = entry.edit.flatMap { $0.max } ?? 100
      let delta = key == .soundUp ? step : -step
      let newVol = max(minVol, min(maxVol, current + delta))
      // Position within the device min...max range. AMBEO uses 0...100, so this matches the hardware step.
      let pct = maxVol > minVol ? Double(newVol - minVol) / Double(maxVol - minVol) : 0.0
      do {
        try await client.set(
          AmbeoEndpoint.Player.Volume(),
          valueJSON: "{\"type\":\"i32_\",\"i32_\":\(newVol)}"
        )
      } catch {
        Logger.audio.warning("Media key: failed to set volume (\(error.localizedDescription))")
        return
      }
      await syncAndShowOverlay(explicitVolume: pct, explicitMute: false)

    default:
      break
    }
  }

  // MARK: - Remote Control & Status Change Sync

  private func handleAmbeoStatusChange(path: String, isExternal: Bool) {
    Task { @MainActor [weak self] in
      guard let self, let client = self.ambeoClient else { return }

      // Decoder audio format change: detect Dolby Atmos from soundbar DSP
      if path == AmbeoEndpoint.Audio.DecoderAudioFormat().path {
        let fmt = await client.state.audioFormat
        let soundbarAtmos = fmt?.isAtmos == true
        Logger.audio.debug(
          "Soundbar audio format: codec=\(fmt?.codec ?? "none"), channels=\(fmt?.channels ?? 0), isAtmos=\(soundbarAtmos)"
        )
        self.evaluateAtmosState(soundbarAtmos: soundbarAtmos)
      }

      // Auto Standby idle time change
      if path == AmbeoEndpoint.System.MaxIdleTime().path {
        let externalTime = await client.state.maxIdleTime
        self.maxIdleTime = externalTime
        if isExternal, self.settings.autoStandbySeconds != externalTime {
          Logger.lifecycle.info(
            "External Auto Standby change detected: syncing app setting to \(externalTime)s"
          )
          self.settings.autoStandbySeconds = externalTime
        }
      }

      // If change was triggered externally (remote control, hardware buttons, app),
      // update state and display the OSD on screen for user-facing audio controls!
      if isExternal {
        let currentPreset = await client.state.preset.lowercased()
        let activeAmbeoLevelPath =
          "settings:/popcorn/audio/audioPresets/ambeoModeLevel_\(currentPreset)"
        let osdEligiblePaths: Set<String> = [
          AmbeoEndpoint.Player.Volume().path,
          AmbeoEndpoint.Player.Mute().path,
          AmbeoEndpoint.Audio.Preset().path,
          AmbeoEndpoint.Audio.AmbeoMode().path,
          AmbeoEndpoint.Audio.NightMode().path,
          AmbeoEndpoint.Audio.VoiceEnhancement().path,
          activeAmbeoLevelPath,
        ]

        if osdEligiblePaths.contains(path) {
          Logger.lifecycle.debug("External change detected on [\(path)]. Displaying synced OSD.")
          self.lastOSDTask?.cancel()
          self.lastOSDTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            await self.syncAndShowOverlay()
          }
        } else {
          Logger.lifecycle.debug(
            "External change detected on [\(path)]. Suppressing OSD (not eligible)."
          )
        }
      }
    }
  }

  // MARK: - Dolby Atmos & Atmos Boost Management

  private func evaluateAtmosState(coreAudioAtmos: Bool? = nil, soundbarAtmos: Bool? = nil) {
    if let ca = coreAudioAtmos { isCoreAudioAtmos = ca }
    if let sa = soundbarAtmos { isSoundbarAtmos = sa }

    let rawIsAtmos = isCoreAudioAtmos || isSoundbarAtmos

    if rawIsAtmos {
      // Atmos detected by CoreAudio or Soundbar DSP
      if let task = atmosDeactivationTask {
        Logger.audio.debug(
          "Dolby Atmos detected while deactivation grace period was pending. Cancelling deactivation."
        )
        task.cancel()
        atmosDeactivationTask = nil
      }

      guard !isAtmosActive else { return }
      isAtmosActive = true
      enqueueAtmosWork { await $0.handleAtmosTransition(isAtmos: true) }
    } else {
      // Atmos is not currently detected
      guard isAtmosActive else {
        atmosDeactivationTask?.cancel()
        atmosDeactivationTask = nil
        return
      }

      // If already waiting during grace period (e.g. track transition or transient handshake), keep waiting
      guard atmosDeactivationTask == nil else { return }

      Logger.audio.debug("Dolby Atmos dropped. Starting deactivation grace period (500ms)...")
      atmosDeactivationTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, let self else { return }
        self.atmosDeactivationTask = nil
        self.isAtmosActive = false
        self.enqueueAtmosWork { await $0.handleAtmosTransition(isAtmos: false) }
      }
    }
  }

  /// Runs Atmos Boost volume changes one at a time, so an apply and a revert never race on the soundbar.
  /// Work already sent to the soundbar is never cancelled mid-request; stale work checks `isAtmosActive` and skips.
  private func enqueueAtmosWork(_ work: @escaping @MainActor (AppModel) async -> Void) {
    let previous = atmosTransitionTask
    atmosTransitionTask = Task { @MainActor [weak self] in
      await previous?.value
      guard !Task.isCancelled, let self else { return }
      await work(self)
    }
  }

  /// Sets the soundbar volume for Atmos Boost. `appliedAtmosBoost` is updated by the caller only when this succeeds.
  private func setBoostVolume(_ client: AmbeoClient, to volume: Int, action: String) async -> Bool {
    do {
      try await client.set(
        AmbeoEndpoint.Player.Volume(),
        valueJSON: "{\"type\":\"i32_\",\"i32_\":\(volume)}"
      )
      return true
    } catch {
      Logger.audio.warning(
        "Atmos Boost \(action) failed: \(error.localizedDescription). Keeping boost state (\(appliedAtmosBoost)%)."
      )
      return false
    }
  }

  private func handleAtmosTransition(isAtmos: Bool) async {
    // A later transition may have flipped the state while this one waited in the queue.
    guard isAtmos == isAtmosActive, let client = ambeoClient else { return }

    if isAtmos {
      Logger.audio.info(
        "Dolby Atmos detected (CoreAudio: \(isCoreAudioAtmos), Soundbar: \(isSoundbarAtmos))"
      )
      if settings.atmosBoostAmount > 0 && appliedAtmosBoost == 0 {
        let boost = Int(settings.atmosBoostAmount)
        guard let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume()) else { return }
        let current = await client.state.volume
        guard !Task.isCancelled, isAtmosActive else { return }
        let minVol = entry.edit.flatMap { $0.min } ?? 0
        let maxVol = entry.edit.flatMap { $0.max } ?? 100
        let newVol = max(minVol, min(maxVol, current + boost))
        let actualBoost = newVol - current

        guard await setBoostVolume(client, to: newVol, action: "apply") else { return }
        appliedAtmosBoost = actualBoost
        Logger.audio.info("Atmos Boost applied: \(current) → \(newVol) (+\(actualBoost)%)")
        await syncAndShowOverlay()
      }
    } else {
      Logger.audio.info("Dolby Atmos ended, stereo playback active.")
      if appliedAtmosBoost > 0 {
        guard let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume()) else { return }
        let current = await client.state.volume
        guard !Task.isCancelled, !isAtmosActive else { return }
        let minVol = entry.edit.flatMap { $0.min } ?? 0
        let maxVol = entry.edit.flatMap { $0.max } ?? 100
        let revertedBoost = appliedAtmosBoost
        let newVol = max(minVol, min(maxVol, current - revertedBoost))

        guard await setBoostVolume(client, to: newVol, action: "revert") else { return }
        appliedAtmosBoost = 0
        Logger.audio.info("Atmos Boost reverted: \(current) → \(newVol) (-\(revertedBoost)%)")
        await syncAndShowOverlay()
      }
    }
  }

  private func handleAtmosBoostAmountChanged(from oldAmount: Double, to newAmount: Double) {
    guard isAtmosActive else { return }

    enqueueAtmosWork { model in
      guard model.isAtmosActive, let client = model.ambeoClient else { return }
      // Read the target at run time: several slider changes may be queued.
      let delta = Int(model.settings.atmosBoostAmount) - model.appliedAtmosBoost
      guard delta != 0 else { return }
      guard let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume()) else { return }
      let current = await client.state.volume
      guard !Task.isCancelled, model.isAtmosActive else { return }
      let minVol = entry.edit.flatMap { $0.min } ?? 0
      let maxVol = entry.edit.flatMap { $0.max } ?? 100
      let newVol = max(minVol, min(maxVol, current + delta))
      let actualDelta = newVol - current

      guard await model.setBoostVolume(client, to: newVol, action: "adjust") else { return }
      model.appliedAtmosBoost = max(0, model.appliedAtmosBoost + actualDelta)
      Logger.audio.info(
        "Atmos Boost adjusted: \(current) → \(newVol) (\(actualDelta >= 0 ? "+" : "")\(actualDelta)%)"
      )
      await model.syncAndShowOverlay()
    }
  }

  // MARK: - Notifications (sleep / wake / screensaver)

  private func setupNotifications() {
    let nc = NSWorkspace.shared.notificationCenter

    nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.startDiscoveringAmbeo()
        self.startMonitoringAudioDevice()
        if self.settings.mediaKeyEnabled { self.startMonitoringSystemEvent() }
        // Reconnect client if configured
        if self.ambeoClient == nil, !self.settings.ambeoUid.isEmpty {
          self.reconnectAmbeoClient()
        }
        Logger.lifecycle.info("Wake from sleep")
      }
    }

    nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.monitoringAudioDeviceTask?.cancel()
        self.monitoringFormatTask?.cancel()
        self.atmosDeactivationTask?.cancel()
        self.atmosDeactivationTask = nil
        self.discoveringAmbeoTask?.cancel()
        self.monitoringSystemEventTask?.cancel()
        self.clientTask?.cancel()
        // Let an in-flight apply/revert finish so appliedAtmosBoost matches the soundbar.
        await self.atmosTransitionTask?.value
        // Revert Atmos Boost before sleeping if active, so the soundbar doesn't stay boosted while sleeping
        if self.appliedAtmosBoost > 0, let client = self.ambeoClient {
          let boost = self.appliedAtmosBoost
          let current = await client.state.volume
          let minVol =
            (await client.getEntry(for: AmbeoEndpoint.Player.Volume()))?.edit.flatMap { $0.min }
            ?? 0
          let newVol = max(minVol, current - boost)
          do {
            try await client.set(
              AmbeoEndpoint.Player.Volume(),
              valueJSON: "{\"type\":\"i32_\",\"i32_\":\(newVol)}"
            )
            self.appliedAtmosBoost = 0
            self.isAtmosActive = false
            self.isCoreAudioAtmos = false
            self.isSoundbarAtmos = false
            Logger.audio.info(
              "Atmos Boost reverted before sleep: \(current) → \(newVol) (-\(boost)%)"
            )
          } catch {
            Logger.audio.warning(
              "Failed to revert Atmos Boost before sleep: \(error.localizedDescription). Preserving boost state across wake."
            )
          }
        }

        let client = self.ambeoClient
        self.ambeoClient = nil
        self.clientGeneration += 1
        await client?.stopObserving()

        Logger.lifecycle.info("Will sleep")
      }
    }

    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // The debounced save may still be pending when the app quits.
      MainActor.assumeIsolated {
        guard let self else { return }
        self.saveTask?.cancel()
        self.saveSettings()
      }
    }

    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("com.apple.screensaver.didstart"),
      object: nil,
      queue: .main
    ) { _ in Logger.lifecycle.info("Screensaver did start") }

    NotificationCenter.default.addObserver(
      forName: .ambeoStatusDidChange,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      let path = notification.userInfo?["path"] as? String
      let isExternal = notification.userInfo?["isExternal"] as? Bool ?? false
      Task { @MainActor [weak self] in
        guard let path else { return }
        self?.handleAmbeoStatusChange(path: path, isExternal: isExternal)
      }
    }
  }

  // MARK: - Settings Persistence

  private func debouncedSaveSettings() {
    saveTask?.cancel()
    saveTask = Task {
      try? await Task.sleep(for: .milliseconds(500))
      if !Task.isCancelled {
        saveSettings()
        Logger.lifecycle.debug("Debounced save executed.")
      }
    }
  }

  private func saveSettings() {
    if let encoded = try? JSONEncoder().encode(settings) {
      UserDefaults.standard.set(encoded, forKey: storageKey)
    }
  }

  // MARK: - Global Keyboard Shortcuts

  private func setupKeyboardShortcuts() {
    KeyboardShortcuts.onKeyDown(for: .toggleAmbeoMode) { [weak self] in
      Task { @MainActor in
        await self?.toggleAmbeoMode()
      }
    }

    KeyboardShortcuts.onKeyDown(for: .cycleAmbeoLevel) { [weak self] in
      Task { @MainActor in
        await self?.cycleAmbeoLevel()
      }
    }

    KeyboardShortcuts.onKeyDown(for: .cyclePreset) { [weak self] in
      Task { @MainActor in
        await self?.cyclePreset()
      }
    }

    KeyboardShortcuts.onKeyDown(for: .toggleNightMode) { [weak self] in
      Task { @MainActor in
        await self?.toggleNightMode()
      }
    }

    KeyboardShortcuts.onKeyDown(for: .toggleVoiceEnhancement) { [weak self] in
      Task { @MainActor in
        await self?.toggleVoiceEnhancement()
      }
    }

    KeyboardShortcuts.onKeyDown(for: .wakeUpSoundbar) { [weak self] in
      Task { @MainActor in
        await self?.wakeUpSoundbar()
      }
    }
  }

  func toggleAmbeoMode() async {
    guard let client = ambeoClient else { return }
    let current = await client.state.isAmbeoMode
    let newMode = !current
    do {
      try await client.set(
        AmbeoEndpoint.Audio.AmbeoMode(),
        valueJSON: "{\"type\":\"bool_\",\"bool_\":\(newMode)}"
      )
    } catch {
      Logger.audio.warning("Shortcut: failed to set AMBEO Mode (\(error.localizedDescription))")
      return
    }
    Logger.audio.info("Shortcut: AMBEO Mode -> \(newMode)")
    await syncAndShowOverlay()
  }

  func cycleAmbeoLevel() async {
    guard let client = ambeoClient else { return }
    let current = await client.state.ambeoLevel.lowercased()
    let levels = AmbeoEndpoint.Audio.AmbeoLevel.allLevels
    let nextLevel: String
    if let idx = levels.firstIndex(of: current) {
      nextLevel = levels[(idx + 1) % levels.count]
    } else {
      nextLevel = "standard"
    }
    let preset = await client.state.preset
    let endpoint = AmbeoEndpoint.Audio.AmbeoLevel(preset: preset)
    do {
      try await client.set(
        endpoint,
        valueJSON: "{\"type\":\"popcornAmbeoModeLevel\",\"popcornAmbeoModeLevel\":\"\(nextLevel)\"}"
      )
    } catch {
      Logger.audio.warning("Shortcut: failed to set AMBEO Level (\(error.localizedDescription))")
      return
    }
    Logger.audio.info("Shortcut: AMBEO Level (\(preset)) -> \(nextLevel)")
    await syncAndShowOverlay()
  }

  func cyclePreset() async {
    guard let client = ambeoClient else { return }
    let presets = AmbeoEndpoint.Audio.Preset.allPresets
    let current = await client.state.preset.lowercased()
    let nextPreset: String
    if let idx = presets.firstIndex(of: current) {
      nextPreset = presets[(idx + 1) % presets.count]
    } else {
      nextPreset = "adaptive"
    }
    do {
      try await client.set(
        AmbeoEndpoint.Audio.Preset(),
        valueJSON: "{\"type\":\"popcornAudioPreset\",\"popcornAudioPreset\":\"\(nextPreset)\"}"
      )
    } catch {
      Logger.audio.warning("Shortcut: failed to set Preset (\(error.localizedDescription))")
      return
    }
    Logger.audio.info("Shortcut: Preset -> \(nextPreset)")
    await syncAndShowOverlay()
  }

  func toggleNightMode() async {
    guard let client = ambeoClient else { return }
    let current = await client.state.isNightMode
    let newNight = !current
    do {
      try await client.set(
        AmbeoEndpoint.Audio.NightMode(),
        valueJSON: "{\"type\":\"bool_\",\"bool_\":\(newNight)}"
      )
    } catch {
      Logger.audio.warning("Shortcut: failed to set Night Mode (\(error.localizedDescription))")
      return
    }
    Logger.audio.info("Shortcut: Night Mode -> \(newNight)")
    await syncAndShowOverlay()
  }

  func toggleVoiceEnhancement() async {
    guard let client = ambeoClient else { return }
    let current = await client.state.isVoiceEnhancement
    let newVoice = !current
    do {
      try await client.set(
        AmbeoEndpoint.Audio.VoiceEnhancement(),
        valueJSON: "{\"type\":\"bool_\",\"bool_\":\(newVoice)}"
      )
    } catch {
      Logger.audio.warning(
        "Shortcut: failed to set Voice Enhancement (\(error.localizedDescription))"
      )
      return
    }
    Logger.audio.info("Shortcut: Voice Enhancement -> \(newVoice)")
    await syncAndShowOverlay()
  }

  func syncAutoStandbyToSoundbar() async {
    guard let client = ambeoClient else { return }
    let target = settings.autoStandbySeconds
    do {
      try await client.set(
        AmbeoEndpoint.System.MaxIdleTime(),
        valueJSON: "{\"type\":\"i32_\",\"i32_\":\(target)}"
      )
      self.maxIdleTime = target
      Logger.lifecycle.info("Synced Auto Standby to soundbar: \(target) seconds")
      await syncAndShowOverlay()
    } catch {
      Logger.lifecycle.error(
        "Failed to sync Auto Standby to soundbar: \(error.localizedDescription)"
      )
    }
  }

  func wakeUpSoundbar() async {
    guard let client = ambeoClient else { return }
    do {
      try await client.activate(path: "ui:/inputs/hdmiTv")
      Logger.lifecycle.info("Shortcut: Soundbar awake requested (HDMI TV activated)")
      if let curDev = currentAudioDevice, curDev.uid == settings.audioDeviceUid {
        applyFallbackFormatIfNeeded(for: curDev)
      }
      await syncAndShowOverlay()
    } catch {
      Logger.lifecycle.error("Failed to awake soundbar: \(error.localizedDescription)")
    }
  }
}
