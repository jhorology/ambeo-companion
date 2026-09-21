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

  private var isCoreAudioAtmos: Bool = false
  private var isSoundbarAtmos: Bool = false
  private(set) var isAtmosActive: Bool = false
  private var appliedAtmosBoost: Int = 0

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
    }
  }

  private(set) var networkDevices: [SennheiserNetworkDevice] = []
  private(set) var currentAudioDevice: AudioDevice? = nil
  private(set) var ambeoClient: AmbeoClient? = nil

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
    clientTask?.cancel()
    ambeoClient = nil
    lastAudioPreset = nil

    guard !settings.ambeoUid.isEmpty,
      let device = networkDevices.first(where: { $0.uuid == settings.ambeoUid })
    else { return }

    let client = AmbeoClient(host: device.ip)
    ambeoClient = client

    clientTask = Task {
      await client.register(AmbeoEndpoint.Player.Volume())
      await client.register(AmbeoEndpoint.Player.Mute())
      await client.register(AmbeoEndpoint.Audio.Preset())
      await client.register(AmbeoEndpoint.Audio.AmbeoMode())
      await client.register(AmbeoEndpoint.Audio.AmbeoLevel(preset: "adaptive"))
      await client.register(AmbeoEndpoint.Audio.NightMode())
      await client.register(AmbeoEndpoint.Audio.VoiceEnhancement())
      await client.register(AmbeoEndpoint.Audio.EcoMode())
      await client.register(AmbeoEndpoint.System.MaxIdleTime())
      await client.register(AmbeoEndpoint.System.Power())
      await client.register(AmbeoEndpoint.Audio.DecoderAudioFormat())
      await client.startObserving()
      await client.markInitialSyncCompleted()

      let initialSoundbarAtmos = await client.state.audioFormat?.isAtmos == true
      await self.evaluateAtmosState(soundbarAtmos: initialSoundbarAtmos)
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

    await self.evaluateAtmosState(coreAudioAtmos: isAtmos)

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
      volumeOverlay.show(volume: explicitVolume, isMuted: explicitMute, isAtmos: isAtmosActive)
      return
    }

    let s = await client.state
    let volPct = explicitVolume ?? (Double(s.volume) / 100.0)
    let muteState = explicitMute ?? s.isMuted

    volumeOverlay.show(
      volume: volPct,
      isMuted: muteState,
      isAmbeoMode: s.isAmbeoMode,
      ambeoLevel: s.ambeoLevel,
      isNightMode: s.isNightMode,
      isVoiceEnhancement: s.isVoiceEnhancement,
      isEcoMode: s.isEcoMode,
      maxIdleTime: s.maxIdleTime,
      powerTarget: s.powerTarget,
      audioPreset: s.preset,
      isAtmos: isAtmosActive
    )
  }

  private func handleMediaKey(_ key: SystemEvent.MediaKey) async {
    guard let client = ambeoClient else { return }

    switch key {
    case .mute:
      let isMuted = await client.state.isMuted
      let newMute = !isMuted
      try? await client.set(
        AmbeoEndpoint.Player.Mute(),
        valueJSON: "{\"type\":\"bool_\",\"bool_\":\(newMute)}"
      )
      await syncAndShowOverlay(explicitMute: newMute)

    case .soundUp, .soundDown:
      guard let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume()) else { return }
      let current = await client.state.volume
      let step: Int = entry.edit.flatMap { $0.step } ?? 1
      let minVol: Int = entry.edit.flatMap { $0.min } ?? 0
      let maxVol: Int = entry.edit.flatMap { $0.max } ?? 100
      let delta = key == .soundUp ? step : -step
      let newVol = Swift.max(minVol, Swift.min(maxVol, current + delta))
      let pct = maxVol > minVol ? Double(newVol - minVol) / Double(maxVol - minVol) : 0.0
      try? await client.set(
        AmbeoEndpoint.Player.Volume(),
        valueJSON: "{\"type\":\"i32_\",\"i32_\":\(newVol)}"
      )
      await syncAndShowOverlay(explicitVolume: pct, explicitMute: false)

    default:
      break
    }
  }

  // MARK: - Remote Control & Status Change Sync

  private func handleAmbeoStatusChange(path: String, isExternal: Bool) {
    Task { @MainActor [weak self] in
      guard let self, let client = self.ambeoClient else { return }

      // Preset change: dynamically update ambeoLevel observation
      if path == AmbeoEndpoint.Audio.Preset().path {
        let preset = await client.state.preset
        await client.register(AmbeoEndpoint.Audio.AmbeoLevel(preset: preset))
      }

      // Decoder audio format change: detect Dolby Atmos from soundbar DSP
      if path == AmbeoEndpoint.Audio.DecoderAudioFormat().path {
        let soundbarAtmos = await client.state.audioFormat?.isAtmos == true
        await self.evaluateAtmosState(soundbarAtmos: soundbarAtmos)
      }

      // If change was triggered externally (remote control, hardware buttons, app),
      // update state and display the OSD on screen!
      if isExternal {
        Logger.lifecycle.debug("External change detected on [\(path)]. Displaying synced OSD.")
        await self.syncAndShowOverlay()
      }
    }
  }

  // MARK: - Dolby Atmos & Atmos Boost Management

  private func evaluateAtmosState(coreAudioAtmos: Bool? = nil, soundbarAtmos: Bool? = nil) async {
    if let ca = coreAudioAtmos { isCoreAudioAtmos = ca }
    if let sa = soundbarAtmos { isSoundbarAtmos = sa }

    let newIsAtmos = isCoreAudioAtmos || isSoundbarAtmos
    guard newIsAtmos != isAtmosActive else { return }
    isAtmosActive = newIsAtmos

    await handleAtmosTransition(isAtmos: newIsAtmos)
  }

  private func handleAtmosTransition(isAtmos: Bool) async {
    guard let client = ambeoClient else { return }

    if isAtmos {
      Logger.audio.info(
        "Dolby Atmos detected (CoreAudio: \(isCoreAudioAtmos), Soundbar: \(isSoundbarAtmos))"
      )
      if settings.atmosBoostAmount > 0 && appliedAtmosBoost == 0 {
        let boost = Int(settings.atmosBoostAmount)
        guard let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume()) else { return }
        let current = await client.state.volume
        let minVol = entry.edit.flatMap { $0.min } ?? 0
        let maxVol = entry.edit.flatMap { $0.max } ?? 100
        let newVol = Swift.max(minVol, Swift.min(maxVol, current + boost))
        appliedAtmosBoost = boost

        try? await client.set(
          AmbeoEndpoint.Player.Volume(),
          valueJSON: "{\"type\":\"i32_\",\"i32_\":\(newVol)}"
        )
        Logger.audio.info("Atmos Boost applied: \(current) → \(newVol) (+\(boost)%)")
        await syncAndShowOverlay()
      }
    } else {
      Logger.audio.info("Dolby Atmos ended, stereo playback active.")
      if appliedAtmosBoost > 0 {
        guard let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume()) else { return }
        let current = await client.state.volume
        let minVol = entry.edit.flatMap { $0.min } ?? 0
        let maxVol = entry.edit.flatMap { $0.max } ?? 100
        let newVol = Swift.max(minVol, Swift.min(maxVol, current - appliedAtmosBoost))
        let revertedBoost = appliedAtmosBoost
        appliedAtmosBoost = 0

        try? await client.set(
          AmbeoEndpoint.Player.Volume(),
          valueJSON: "{\"type\":\"i32_\",\"i32_\":\(newVol)}"
        )
        Logger.audio.info("Atmos Boost reverted: \(current) → \(newVol) (-\(revertedBoost)%)")
        await syncAndShowOverlay()
      }
    }
  }

  private func handleAtmosBoostAmountChanged(from oldAmount: Double, to newAmount: Double) {
    guard isAtmosActive, appliedAtmosBoost > 0 else { return }
    let newBoost = Int(newAmount)
    let delta = newBoost - appliedAtmosBoost
    guard delta != 0 else { return }

    Task {
      guard let client = self.ambeoClient else { return }
      guard let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume()) else { return }
      let current = await client.state.volume
      let minVol = entry.edit.flatMap { $0.min } ?? 0
      let maxVol = entry.edit.flatMap { $0.max } ?? 100
      let newVol = Swift.max(minVol, Swift.min(maxVol, current + delta))
      self.appliedAtmosBoost = newBoost

      try? await client.set(
        AmbeoEndpoint.Player.Volume(),
        valueJSON: "{\"type\":\"i32_\",\"i32_\":\(newVol)}"
      )
      Logger.audio.info(
        "Atmos Boost adjusted: \(current) → \(newVol) (\(delta >= 0 ? "+" : "")\(delta)%)"
      )
      await self.syncAndShowOverlay()
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
        Logger.lifecycle.info("Wake from sleep")
      }
    }

    nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.monitoringAudioDeviceTask?.cancel()
        self.monitoringFormatTask?.cancel()
        self.discoveringAmbeoTask?.cancel()
        self.monitoringSystemEventTask?.cancel()
        self.clientTask?.cancel()
        Logger.lifecycle.info("Will sleep")
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
  }

  func toggleAmbeoMode() async {
    guard let client = ambeoClient else { return }
    let current = await client.state.isAmbeoMode
    let newMode = !current
    try? await client.set(
      AmbeoEndpoint.Audio.AmbeoMode(),
      valueJSON: "{\"type\":\"bool_\",\"bool_\":\(newMode)}"
    )
    Logger.audio.info("Shortcut: AMBEO Mode -> \(newMode)")
    await syncAndShowOverlay()
  }

  func cycleAmbeoLevel() async {
    guard let client = ambeoClient else { return }
    let current = await client.state.ambeoLevel.lowercased()
    let levels = ["light", "standard", "boost"]
    let nextLevel: String
    if let idx = levels.firstIndex(of: current) {
      nextLevel = levels[(idx + 1) % levels.count]
    } else {
      nextLevel = "standard"
    }
    let preset = await client.state.preset
    let endpoint = AmbeoEndpoint.Audio.AmbeoLevel(preset: preset)
    try? await client.set(
      endpoint,
      valueJSON: "{\"type\":\"string_\",\"string_\":\"\(nextLevel)\"}"
    )
    Logger.audio.info("Shortcut: AMBEO Level -> \(nextLevel)")
    await syncAndShowOverlay()
  }

  func cyclePreset() async {
    guard let client = ambeoClient else { return }
    let presets = ["adaptive", "music", "movie", "news", "neutral", "sports"]
    let current = await client.state.preset.lowercased()
    let nextPreset: String
    if let idx = presets.firstIndex(of: current) {
      nextPreset = presets[(idx + 1) % presets.count]
    } else {
      nextPreset = "adaptive"
    }
    try? await client.set(
      AmbeoEndpoint.Audio.Preset(),
      valueJSON: "{\"type\":\"string_\",\"string_\":\"\(nextPreset)\"}"
    )
    await client.register(AmbeoEndpoint.Audio.AmbeoLevel(preset: nextPreset))
    Logger.audio.info("Shortcut: Preset -> \(nextPreset)")
    await syncAndShowOverlay()
  }

  func toggleNightMode() async {
    guard let client = ambeoClient else { return }
    let current = await client.state.isNightMode
    let newNight = !current
    try? await client.set(
      AmbeoEndpoint.Audio.NightMode(),
      valueJSON: "{\"type\":\"bool_\",\"bool_\":\(newNight)}"
    )
    Logger.audio.info("Shortcut: Night Mode -> \(newNight)")
    await syncAndShowOverlay()
  }

  func toggleVoiceEnhancement() async {
    guard let client = ambeoClient else { return }
    let current = await client.state.isVoiceEnhancement
    let newVoice = !current
    try? await client.set(
      AmbeoEndpoint.Audio.VoiceEnhancement(),
      valueJSON: "{\"type\":\"bool_\",\"bool_\":\(newVoice)}"
    )
    Logger.audio.info("Shortcut: Voice Enhancement -> \(newVoice)")
    await syncAndShowOverlay()
  }
}
