import AmbeoCore
import AppKit
import CoreAudio
import Foundation
import Logging
import Observation

/// Top-level application facade that binds the SwiftUI views (`AmbeoCompanionApp`, `SettingsView`,
/// `PermissionOnboardingView`) and system lifecycle events to the focused domain coordinators.
@Observable @MainActor final class AppModel: Sendable {
  static weak var runningInstance: AppModel?

  let settingsStore: AppSettingsStore
  let discovery: SoundbarDiscoveryController
  let session: SoundbarSession
  let audioFormat: AudioFormatCoordinator
  let mediaKeys: MediaKeyCoordinator
  let volumeOverlay: any VolumeOverlayPresenting

  private(set) var atmosBoost: AtmosBoostCoordinator!
  private(set) var stealthRewindCoordinator: StealthRewindCoordinator?
  private(set) var mediaKeyPermissions = MediaKeyPermissions.current()

  private var isShuttingDown = false
  private var lastOSDTask: Task<Void, Never>?

  // MARK: - Observable State Forwarded to UI & Tests

  var settings: AppSettings {
    didSet {
      settingsStore.debouncedSave(settings)
      if settings.ambeoUid != oldValue.ambeoUid { reconnectAmbeoClient() }
      if settings.audioDeviceUid != oldValue.audioDeviceUid {
        updateFormatMonitoringForActiveDevice()
        if let current = currentAudioDevice, current.uid == settings.audioDeviceUid {
          audioFormat.applyFallbackFormatIfNeeded(
            for: current,
            fallbackFormatID: settings.fallbackAudioFormatID
          )
        }
        restartSystemEventMonitorIfNeeded()
      }
      if settings.mediaKeyEnabled != oldValue.mediaKeyEnabled {
        restartSystemEventMonitorIfNeeded()
      }
      if settings.stealthRewindEnabled != oldValue.stealthRewindEnabled {
        handleStealthRewindEnabledChanged()
      }
      if settings.stealthRewindDelayMs != oldValue.stealthRewindDelayMs {
        stealthRewindCoordinator?.settleDelay = .milliseconds(settings.stealthRewindDelayMs)
      }
      if settings.atmosBoostAmount != oldValue.atmosBoostAmount {
        atmosBoost.handleBoostAmountChanged(
          from: oldValue.atmosBoostAmount,
          to: settings.atmosBoostAmount
        )
      }
      if settings.autoStandbySeconds != oldValue.autoStandbySeconds,
        settings.autoStandbySeconds != maxIdleTime
      {
        Task { [weak self] in await self?.syncAutoStandbyToSoundbar() }
      }
    }
  }

  var isLaunchAtLoginEnabled: Bool {
    get { settingsStore.launchAtLoginState }
    set {
      settingsStore.launchAtLoginState = newValue
      settingsStore.setLaunchAtLogin(enabled: newValue)
    }
  }

  var needsPermissionOnboarding: Bool {
    let mediaKeysNeeded = settings.mediaKeyEnabled && !mediaKeyPermissions.mediaKeysGranted
    let musicAutomationNeeded =
      settings.stealthRewindEnabled
      && (mediaKeyPermissions.musicAutomation == .notDetermined
        || mediaKeyPermissions.musicAutomation == .denied)
    return mediaKeysNeeded || musicAutomationNeeded
  }

  var networkDevices: [SennheiserNetworkDevice] {
    get { discovery.networkDevices }
    set { discovery.networkDevices = newValue }
  }

  var discoveryStartedAt: ContinuousClock.Instant? { discovery.discoveryStartedAt }

  var discoveryGraceElapsed: Bool {
    get { discovery.discoveryGraceElapsed }
    set { discovery.discoveryGraceElapsed = newValue }
  }

  var localNetworkStatus: LocalNetworkPermissionStatus {
    discovery.localNetworkStatus(hasClient: ambeoClient != nil)
  }

  var currentAudioDevice: AudioDevice? { audioFormat.currentAudioDevice }
  var availableAudioDevices: [AudioDevice] { audioFormat.availableAudioDevices }

  var ambeoClient: AmbeoClient? {
    get { session.ambeoClient }
    set { session.ambeoClient = newValue }
  }

  var soundbarState: AmbeoState? { session.soundbarState }
  var maxIdleTime: Int { session.maxIdleTime }

  var isAtmosActive: Bool { atmosBoost.isAtmosActive }

  var connectedUid: String {
    get { atmosBoost.connectedUid }
    set { atmosBoost.connectedUid = newValue }
  }

  var appliedAtmosBoost: Int {
    get { atmosBoost.appliedAtmosBoost }
    set { atmosBoost.appliedAtmosBoost = newValue }
  }

  var deferredBoostReasonWhileMuted: String? {
    get { atmosBoost.deferredBoostReasonWhileMuted }
    set { atmosBoost.deferredBoostReasonWhileMuted = newValue }
  }

  // MARK: - Initialization

  /// `autostart` is false in tests so unit tests can inspect and drive state without starting mDNS
  /// browsing, CoreAudio subscriptions, CGEventTap, workspace notifications or global shortcuts.
  init(
    settings initialSettings: AppSettings? = nil,
    settingsStore: AppSettingsStore = AppSettingsStore(),
    discovery: SoundbarDiscoveryController = SoundbarDiscoveryController(),
    session: SoundbarSession = SoundbarSession(),
    audioFormat: AudioFormatCoordinator = AudioFormatCoordinator(),
    mediaKeys: MediaKeyCoordinator = MediaKeyCoordinator(),
    autostart: Bool = true,
    volumeOverlay overlay: any VolumeOverlayPresenting = VolumeOverlayManager()
  ) {
    self.settingsStore = settingsStore
    self.discovery = discovery
    self.session = session
    self.audioFormat = audioFormat
    self.mediaKeys = mediaKeys
    self.volumeOverlay = overlay
    self.settings = initialSettings ?? settingsStore.load()

    Self.runningInstance = self

    stealthRewindCoordinator = StealthRewindCoordinator(
      settleDelay: .milliseconds(settings.stealthRewindDelayMs),
      muteTimeout: StealthRewindCoordinator.defaultMuteTimeout,
      musicPlayer: MusicPlayerController.shared,
      isMutedProvider: { [weak self] in
        guard let self, let client = self.session.activeOrDisconnectingClient else { return nil }
        return await client.getValue(for: AmbeoEndpoint.Player.Mute())
      },
      setMute: { [weak self] muted in
        guard let self, let client = self.session.activeOrDisconnectingClient else {
          throw URLError(.notConnectedToInternet)
        }
        try await client.set(
          AmbeoEndpoint.Player.Mute(),
          valueJSON: "{\"type\":\"bool_\",\"bool_\":\(muted)}",
          timeout: AmbeoClient.interactiveTimeout
        )
        await self.session.refreshSoundbarState(from: client)
      },
      currentSoundbarFormatProvider: { [weak self] in
        guard let self, let client = self.ambeoClient else { return nil }
        return await client.state.audioFormat
      }
    )

    atmosBoost = AtmosBoostCoordinator(
      clientProvider: { [weak self] in self?.ambeoClient },
      boostAmountProvider: { [weak self] in self?.settings.atmosBoostAmount ?? 0 },
      cachedIsMutedProvider: { [weak self] in self?.soundbarState?.isMuted },
      waitForStealthRewind: { [weak self] in
        await self?.stealthRewindCoordinator?.waitForActiveSession()
      },
      onShowOverlay: { [weak self] in await self?.syncAndShowOverlay() }
    )

    if autostart { startServices() }
  }

  private func startServices() {
    settingsStore.checkLaunchAtLoginStatus()
    startDiscoveringAmbeo()
    startMonitoringAudioDevice()
    if settings.mediaKeyEnabled { startMonitoringSystemEvent() }
    Task { [weak self] in await self?.refreshMediaKeyPermissions() }
    setupNotifications()
    setupKeyboardShortcuts()
  }

  // MARK: - Discovery & Session Wiring

  nonisolated static func shouldReconnectForIPChange(host: String?, discoveredIP: String?) -> Bool {
    SoundbarDiscoveryController.shouldReconnectForIPChange(host: host, discoveredIP: discoveredIP)
  }

  private func startDiscoveringAmbeo() {
    discovery.startDiscovering(
      selectedUid: { [weak self] in self?.settings.ambeoUid ?? "" },
      hasClient: { [weak self] in self?.ambeoClient != nil },
      currentHost: { [weak self] in await self?.ambeoClient?.host },
      onReconnectNeeded: { [weak self] in self?.reconnectAmbeoClient() }
    )
  }

  private func reconnectAmbeoClient() {
    guard !isShuttingDown else { return }
    let previousTransition = atmosBoost.prepareForReconnect()
    let uid = settings.ambeoUid
    let host = discovery.host(for: uid)

    session.reconnect(
      uid: uid,
      host: host,
      isShuttingDown: isShuttingDown,
      onCancelStealthRewind: { [weak self] in
        await self?.stealthRewindCoordinator?.cancelAndUnmuteIfNeeded(reason: "client reconnect")
      },
      onWaitPreviousAtmosTransition: { await previousTransition?.value },
      onRevertBoostIfDeviceChanged: { [weak self] previousClient, targetUid in
        guard let self, targetUid != self.connectedUid else { return }
        await self.atmosBoost.revertOutstandingBoost(using: previousClient)
      },
      onClientAssigned: { [weak self] connectedUid in
        self?.atmosBoost.assignConnectedDevice(uid: connectedUid)
      },
      onInitialSyncCompleted: { [weak self] client, initialState in
        guard let self else { return }
        let generation = self.session.clientGeneration
        await self.stealthRewindCoordinator?.retryPendingUnmute(reason: "client connected")
        guard generation == self.session.clientGeneration, self.ambeoClient === client else {
          return
        }

        let initialSoundbarAtmos = initialState.audioFormat?.isAtmos == true
        let initialMaxIdleTime = initialState.maxIdleTime
        if initialMaxIdleTime != self.settings.autoStandbySeconds {
          Logger.lifecycle.info(
            "Auto Standby mismatch detected (soundbar: \(initialMaxIdleTime)s, app setting: \(self.settings.autoStandbySeconds)s). Enforcing app setting."
          )
          await self.syncAutoStandbyToSoundbar()
        } else {
          self.session.maxIdleTime = initialMaxIdleTime
        }
        self.atmosBoost.evaluateAtmosState(soundbarAtmos: initialSoundbarAtmos)
      }
    )
  }

  // MARK: - Audio Device & Format Wiring

  private func startMonitoringAudioDevice() {
    audioFormat.startMonitoring(
      targetUID: { [weak self] in self?.settings.audioDeviceUid ?? "" },
      fallbackFormatID: { [weak self] in self?.settings.fallbackAudioFormatID ?? "" },
      onRecoveredUID: { [weak self] recovered in self?.settings.audioDeviceUid = recovered },
      onResetFormatObserver: { [weak self] in self?.stealthRewindCoordinator?.resetObservedFormat()
      },
      onFormatChange: { [weak self] format, device in
        await self?.handleAudioFormatChange(format, for: device)
      }
    )
  }

  private func updateFormatMonitoringForActiveDevice() {
    audioFormat.updateFormatMonitoringForActiveDevice(
      targetUID: settings.audioDeviceUid,
      onResetFormatObserver: { [weak self] in self?.stealthRewindCoordinator?.resetObservedFormat()
      },
      onFormatChange: { [weak self] format, device in
        await self?.handleAudioFormatChange(format, for: device)
      }
    )
  }

  private func handleAudioFormatChange(
    _ format: AudioPhysicalFormat?,
    for device: AudioDevice
  ) async {
    let wasAtmos = atmosBoost.isCoreAudioAtmos
    let isAtmos = format?.isAtmosOrMultichannel == true

    Logger.audio.info(
      "Audio format on [\(device.name)]: \(format?.displayName ?? "unknown") (formatID=\(format?.formatID ?? 0) '\(format?.fourCCString ?? "")', isAtmosOrMultichannel=\(isAtmos))"
    )

    // Trigger Stealth Rewind before Atmos Boost so Mute is asserted immediately and Atmos Boost
    // waits until Stealth Rewind completes before writing player:volume.
    await stealthRewindCoordinator?.handleCoreAudioFormatChange(
      format,
      deviceID: device.id,
      isEnabled: settings.stealthRewindEnabled,
      isClientConnected: ambeoClient != nil
    )

    atmosBoost.evaluateAtmosState(coreAudioAtmos: isAtmos)

    if wasAtmos && !isAtmos {
      audioFormat.applyFallbackFormatIfNeeded(
        for: device,
        fallbackFormatID: settings.fallbackAudioFormatID
      )
    }
  }

  // MARK: - Permissions & Media Keys Wiring

  func refreshMediaKeyPermissions() async {
    let current = await Task.detached { MediaKeyPermissions.current() }.value
    guard !Task.isCancelled, !isShuttingDown, current != mediaKeyPermissions else { return }
    mediaKeyPermissions = current
    restartSystemEventMonitorIfNeeded()
    if current.musicAutomation == .granted {
      MusicPlayerController.shared.refreshPlaybackStateInBackground()
    } else if current.musicAutomation == .denied {
      await stealthRewindCoordinator?.cancelAndUnmuteIfNeeded(
        reason: "Music.app Automation permission denied"
      )
    }
  }

  private func handleStealthRewindEnabledChanged() {
    if settings.stealthRewindEnabled {
      Task { [weak self] in
        await self?.refreshMediaKeyPermissions()
        guard let self else { return }
        if self.mediaKeyPermissions.isGranted(.musicAutomation) {
          MusicPlayerController.shared.refreshPlaybackStateInBackground()
        } else {
          MediaKeyPermission.musicAutomation.requestAndOpenSettings {
            await self.refreshMediaKeyPermissions()
            MusicPlayerController.shared.refreshPlaybackStateInBackground()
          }
        }
      }
    } else {
      Task { [weak self] in
        await self?.stealthRewindCoordinator?.cancelAndUnmuteIfNeeded(
          reason: "disabled in settings"
        )
      }
    }
  }

  private func restartSystemEventMonitorIfNeeded() {
    mediaKeys.stopMonitoring()
    if settings.mediaKeyEnabled { startMonitoringSystemEvent() }
  }

  func startMonitoringSystemEvent() {
    mediaKeys.startMonitoring(
      isShuttingDown: isShuttingDown,
      mediaKeyEnabled: settings.mediaKeyEnabled,
      mediaKeysGranted: mediaKeyPermissions.mediaKeysGranted,
      audioDeviceUid: settings.audioDeviceUid,
      onMediaKey: { [weak self] key in await self?.handleMediaKey(key) },
      onStreamEnded: { [weak self] in
        guard let self, !self.isShuttingDown else { return }
        await self.refreshMediaKeyPermissions()
      }
    )
  }

  private func handleMediaKey(_ key: SystemEvent.MediaKey) async {
    guard !isShuttingDown, let client = ambeoClient else { return }
    switch key {
    case .mute:
      guard let newMute = await SoundbarCommandController.toggleMute(client: client) else { return }
      await syncAndShowOverlay(explicitMute: newMute)
      if !newMute { atmosBoost.replayDeferredVolumeWork(afterUnmute: "media key") }
    case .soundUp, .soundDown:
      guard let pct = await SoundbarCommandController.adjustVolume(direction: key, client: client)
      else { return }
      await syncAndShowOverlay(explicitVolume: pct, explicitMute: false)
    default: break
    }
  }

  // MARK: - OSD & Telemetry Status Sync

  private func syncAndShowOverlay(explicitVolume: Double? = nil, explicitMute: Bool? = nil) async {
    await volumeOverlay.syncAndShow(
      from: ambeoClient,
      isAtmosActive: isAtmosActive,
      explicitVolume: explicitVolume,
      explicitMute: explicitMute
    )
  }

  func handleAmbeoStatusChange(path: String, isExternal: Bool) {
    Task { @MainActor [weak self] in
      guard let self, let client = self.ambeoClient else { return }

      let wasMuted = self.soundbarState?.isMuted
      let latestState = await client.state
      guard client === self.ambeoClient else { return }
      self.session.soundbarState = latestState

      if path == AmbeoEndpoint.Player.Mute().path, wasMuted == true, !latestState.isMuted {
        self.atmosBoost.replayDeferredVolumeWork(afterUnmute: "mute telemetry")
      }

      if path == AmbeoEndpoint.Audio.DecoderAudioFormat().path {
        let fmt = await client.state.audioFormat
        let soundbarAtmos = fmt?.isAtmos == true
        Logger.audio.debug(
          "Soundbar audio format: codec=\(fmt?.codec ?? "none"), channels=\(fmt?.channels ?? 0), isAtmos=\(soundbarAtmos)"
        )
        self.stealthRewindCoordinator?.handleSoundbarFormatChange(fmt)
        self.atmosBoost.evaluateAtmosState(soundbarAtmos: soundbarAtmos)
      }

      if path == AmbeoEndpoint.System.MaxIdleTime().path {
        let externalTime = await client.state.maxIdleTime
        self.session.maxIdleTime = externalTime
        if isExternal, self.settings.autoStandbySeconds != externalTime {
          Logger.lifecycle.info(
            "External Auto Standby change detected: syncing app setting to \(externalTime)s"
          )
          self.settings.autoStandbySeconds = externalTime
        }
      }

      if isExternal {
        let currentPreset = await client.state.preset
        if path == AmbeoEndpoint.Player.Mute().path,
          self.stealthRewindCoordinator?.isSuppressingMuteOSD == true
        {
          Logger.lifecycle.debug(
            "External change on [\(path)] suppressed while Stealth Rewind is active."
          )
        } else if SoundbarCommandController.isOSDEligible(path: path, currentPreset: currentPreset)
        {
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

  // MARK: - Atmos Boost Forwarding (for Tests)

  func setBoostVolume(_ client: AmbeoClient, to volume: Int, action: String) async -> Bool {
    await atmosBoost.setBoostVolume(client, to: volume, action: action)
  }

  func isSoundbarMuted(_ client: AmbeoClient) async -> Bool {
    await atmosBoost.isSoundbarMuted(client)
  }

  func replayDeferredAtmosVolumeWork(afterUnmute reason: String) {
    atmosBoost.replayDeferredVolumeWork(afterUnmute: reason)
  }

  // MARK: - Soundbar Remote Actions & Shortcuts

  private func setupKeyboardShortcuts() {
    mediaKeys.setupKeyboardShortcuts(
      onToggleAmbeoMode: { [weak self] in await self?.toggleAmbeoMode() },
      onCycleAmbeoLevel: { [weak self] in await self?.cycleAmbeoLevel() },
      onCyclePreset: { [weak self] in await self?.cyclePreset() },
      onToggleNightMode: { [weak self] in await self?.toggleNightMode() },
      onToggleVoiceEnhancement: { [weak self] in await self?.toggleVoiceEnhancement() },
      onWakeUpSoundbar: { [weak self] in await self?.wakeUpSoundbar() }
    )
  }

  func toggleAmbeoMode() async {
    guard let client = ambeoClient, await SoundbarCommandController.toggleAmbeoMode(client: client)
    else { return }
    await session.refreshSoundbarState(from: client)
    await syncAndShowOverlay()
  }

  func cycleAmbeoLevel() async {
    guard let client = ambeoClient, await SoundbarCommandController.cycleAmbeoLevel(client: client)
    else { return }
    await session.refreshSoundbarState(from: client)
    await syncAndShowOverlay()
  }

  func setAmbeoLevel(_ level: String) async {
    guard let client = ambeoClient,
      await SoundbarCommandController.setAmbeoLevel(level, client: client)
    else { return }
    await session.refreshSoundbarState(from: client)
    await syncAndShowOverlay()
  }

  func cyclePreset() async {
    guard let client = ambeoClient, await SoundbarCommandController.cyclePreset(client: client)
    else { return }
    await session.refreshSoundbarState(from: client)
    await syncAndShowOverlay()
  }

  func setPreset(_ preset: String) async {
    guard let client = ambeoClient,
      await SoundbarCommandController.setPreset(preset, client: client)
    else { return }
    await session.refreshSoundbarState(from: client)
    await syncAndShowOverlay()
  }

  func toggleNightMode() async {
    guard let client = ambeoClient, await SoundbarCommandController.toggleNightMode(client: client)
    else { return }
    await session.refreshSoundbarState(from: client)
    await syncAndShowOverlay()
  }

  func toggleVoiceEnhancement() async {
    guard let client = ambeoClient,
      await SoundbarCommandController.toggleVoiceEnhancement(client: client)
    else { return }
    await session.refreshSoundbarState(from: client)
    await syncAndShowOverlay()
  }

  func syncAutoStandbyToSoundbar() async {
    guard let client = ambeoClient else { return }
    let target = settings.autoStandbySeconds
    guard await SoundbarCommandController.syncAutoStandby(target, client: client) else { return }
    session.maxIdleTime = target
    await syncAndShowOverlay()
  }

  func wakeUpSoundbar() async {
    guard let client = ambeoClient, await SoundbarCommandController.wakeUp(client: client) else {
      return
    }
    if let curDev = currentAudioDevice, curDev.uid == settings.audioDeviceUid {
      audioFormat.applyFallbackFormatIfNeeded(
        for: curDev,
        fallbackFormatID: settings.fallbackAudioFormatID
      )
    }
    await syncAndShowOverlay()
  }

  // MARK: - System Lifecycle (Sleep / Wake / Termination)

  func prepareForTermination() async {
    isShuttingDown = true
    atmosBoost.isShuttingDown = true
    settingsStore.flushAndSaveNow(settings)
    discovery.stopDiscovering()
    let activeClient = await session.waitForTermination()
    audioFormat.stopMonitoring(onResetFormatObserver: { [weak self] in
      self?.stealthRewindCoordinator?.resetObservedFormat()
    })
    mediaKeys.stopMonitoring()
    await stealthRewindCoordinator?.cancelAndUnmuteIfNeeded(reason: "app termination")
    await atmosBoost.cancelDeactivationAndWaitForTransition()
    if let client = activeClient {
      await atmosBoost.revertOutstandingBoost(using: client)
      await client.shutdown()
    }
  }

  private func setupNotifications() {
    let nc = NSWorkspace.shared.notificationCenter

    nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.startDiscoveringAmbeo()
        self.startMonitoringAudioDevice()
        await self.refreshMediaKeyPermissions()
        if self.settings.mediaKeyEnabled { self.startMonitoringSystemEvent() }
        if self.ambeoClient == nil, !self.settings.ambeoUid.isEmpty { self.reconnectAmbeoClient() }
        Logger.lifecycle.info("Wake from sleep")
      }
    }

    nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.audioFormat.stopMonitoring(onResetFormatObserver: { [weak self] in
          self?.stealthRewindCoordinator?.resetObservedFormat()
        })
        self.discovery.stopDiscovering()
        self.mediaKeys.stopMonitoring()
        self.session.cancelConnectionTask()
        await self.stealthRewindCoordinator?.cancelAndUnmuteIfNeeded(reason: "system sleep")
        await self.atmosBoost.revertBeforeSleep(using: self.ambeoClient)
        await self.session.dropAndShutdownCurrentClient()
        Logger.lifecycle.info("Will sleep")
      }
    }

    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.settingsStore.flushAndSaveNow(self.settings)
      }
    }

    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in Task { @MainActor [weak self] in await self?.refreshMediaKeyPermissions() }
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
}
