import AmbeoCore
import Foundation
import Logging
import Observation

/// Coordinates Dolby Atmos detection (combining CoreAudio physical format and AMBEO DSP format)
/// and Atmos Boost volume adjustments:
/// - Applies a 500 ms deactivation grace period to ignore transient format drops during track switches
/// - Serializes apply / adjust / revert volume writes in an ordered transition queue
/// - Refuses volume writes while the soundbar is muted (since `player:volume` unmutes AMBEO hardware)
///   and replays the deferred adjustment on the next unmute
/// - Persists applied boost amounts per soundbar UID in `AtmosBoostLedger` so reconnects and restarts
///   never double-boost
@Observable @MainActor final class AtmosBoostCoordinator {
  static let defaultDeactivationGrace: Duration = .milliseconds(500)

  var deactivationGrace: Duration
  let boostLedger: AtmosBoostLedger

  private(set) var isCoreAudioAtmos: Bool = false
  private(set) var isSoundbarAtmos: Bool = false
  private(set) var isAtmosActive: Bool = false
  var connectedUid: String = ""
  var isShuttingDown: Bool = false

  /// Why an Atmos Boost volume write was skipped while the user had muted the soundbar. Every
  /// `player:volume` write unmutes AMBEO hardware, so the adjustment is deferred and replayed on
  /// the next unmute instead of overriding the user's mute.
  var deferredBoostReasonWhileMuted: String? = nil

  var appliedAtmosBoost: Int {
    get { boostLedger.amount(for: connectedUid) }
    set { boostLedger.record(newValue, for: connectedUid) }
  }

  private let clientProvider: @MainActor () -> AmbeoClient?
  private let boostAmountProvider: @MainActor () -> Double
  private let cachedIsMutedProvider: @MainActor () -> Bool?
  private let waitForStealthRewind: @MainActor () async -> Void
  private let onShowOverlay: @MainActor () async -> Void

  private var atmosDeactivationTask: Task<Void, Never>?
  private var atmosTransitionTask: Task<Void, Never>?

  init(
    boostLedger: AtmosBoostLedger = AtmosBoostLedger(key: "\(Bundle.id).AtmosBoostLedger"),
    deactivationGrace: Duration = AtmosBoostCoordinator.defaultDeactivationGrace,
    clientProvider: @escaping @MainActor () -> AmbeoClient?,
    boostAmountProvider: @escaping @MainActor () -> Double,
    cachedIsMutedProvider: @escaping @MainActor () -> Bool?,
    waitForStealthRewind: @escaping @MainActor () async -> Void = {},
    onShowOverlay: @escaping @MainActor () async -> Void = {}
  ) {
    self.boostLedger = boostLedger
    self.deactivationGrace = deactivationGrace
    self.clientProvider = clientProvider
    self.boostAmountProvider = boostAmountProvider
    self.cachedIsMutedProvider = cachedIsMutedProvider
    self.waitForStealthRewind = waitForStealthRewind
    self.onShowOverlay = onShowOverlay
  }

  // MARK: - Connection & Lifecycle Hooks

  /// Preserves boost state across reconnections to prevent double-boosting and returns the
  /// in-flight transition task so the caller can wait for it before dropping the previous client.
  func prepareForReconnect() -> Task<Void, Never>? {
    atmosDeactivationTask?.cancel()
    atmosDeactivationTask = nil
    let previousTransition = atmosTransitionTask
    // If a boost was already applied to the soundbar hardware, resetting appliedAtmosBoost to 0
    // would cause the re-established client to apply another boost on top (+25% twice).
    isAtmosActive = appliedAtmosBoost > 0
    isSoundbarAtmos = false
    return previousTransition
  }

  func assignConnectedDevice(uid: String) {
    connectedUid = uid
    isAtmosActive = appliedAtmosBoost > 0
  }

  func evaluateAtmosState(coreAudioAtmos: Bool? = nil, soundbarAtmos: Bool? = nil) {
    if let ca = coreAudioAtmos { isCoreAudioAtmos = ca }
    if let sa = soundbarAtmos { isSoundbarAtmos = sa }

    guard !isShuttingDown else { return }
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

      let grace = deactivationGrace
      Logger.audio.debug("Dolby Atmos dropped. Starting deactivation grace period (\(grace))...")
      atmosDeactivationTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: grace)
        guard !Task.isCancelled, let self else { return }
        self.atmosDeactivationTask = nil
        self.isAtmosActive = false
        self.enqueueAtmosWork { await $0.handleAtmosTransition(isAtmos: false) }
      }
    }
  }

  /// Runs Atmos Boost volume changes one at a time, so an apply and a revert never race on the soundbar.
  /// Work already sent to the soundbar is never cancelled mid-request; stale work checks `isAtmosActive` and skips.
  private func enqueueAtmosWork(_ work: @escaping @MainActor (AtmosBoostCoordinator) async -> Void)
  {
    let previous = atmosTransitionTask
    atmosTransitionTask = Task { @MainActor [weak self] in
      await previous?.value
      guard !Task.isCancelled, let self else { return }
      await work(self)
    }
  }

  // MARK: - Volume Write & Mute Safety

  /// Sets the soundbar volume for Atmos Boost. `appliedAtmosBoost` is updated by the caller only when this succeeds.
  /// Returns false when the write was skipped (muted, or the request failed); the caller keeps its boost state.
  func setBoostVolume(_ client: AmbeoClient, to volume: Int, action: String) async -> Bool {
    // Writing `player:volume` on AMBEO hardware automatically unmutes the soundbar. A user mute
    // outranks the boost: defer it and replay on the next unmute.
    if await isSoundbarMuted(client) {
      deferredBoostReasonWhileMuted = action
      Logger.audio.info(
        "Atmos Boost \(action) skipped: soundbar is muted, and a volume write would unmute it. Will retry when unmuted (\(isAtmosActive ? "Atmos active" : "stereo"))."
      )
      return false
    }
    do {
      try await client.set(
        AmbeoEndpoint.Player.Volume(),
        valueJSON: "{\"type\":\"i32_\",\"i32_\":\(volume)}",
        timeout: AmbeoClient.interactiveTimeout
      )
      return true
    } catch {
      Logger.audio.warning(
        "Atmos Boost \(action) failed: \(error.localizedDescription). Keeping boost state (\(appliedAtmosBoost)%)."
      )
      return false
    }
  }

  /// Whether the soundbar is muted. `getValue` reads the client's in-memory `latestValues`, which
  /// the long-poll subscription queue keeps fresh, so this is not an extra request (it fetches only
  /// when nothing is cached yet). When no value is available the cached snapshot is used, and an
  /// unknown state counts as muted because deferring is recoverable while silently unmuting is not.
  func isSoundbarMuted(_ client: AmbeoClient) async -> Bool {
    if let fresh = await client.getValue(
      for: AmbeoEndpoint.Player.Mute(),
      timeout: AmbeoClient.interactiveTimeout
    ) {
      return fresh
    }
    return cachedIsMutedProvider() ?? true
  }

  /// Replays the Atmos Boost volume write that `setBoostVolume` deferred while the soundbar was
  /// muted. The target is recomputed from the current state, so a mute spanning an Atmos
  /// transition ends up with the correct direction (apply while Atmos, revert in stereo).
  func replayDeferredVolumeWork(afterUnmute reason: String) {
    guard let action = deferredBoostReasonWhileMuted else { return }
    deferredBoostReasonWhileMuted = nil
    let targetAmount = boostAmountProvider()
    guard !isShuttingDown, targetAmount > 0 else { return }
    Logger.audio.info("Soundbar unmuted (\(reason)); replaying deferred Atmos Boost \(action).")
    if isAtmosActive {
      // Recomputes `atmosBoostAmount - appliedAtmosBoost` at run time, covering both apply and
      // slider-adjust cases, and serializes its own volume write.
      handleBoostAmountChanged(from: targetAmount, to: targetAmount)
    } else {
      enqueueAtmosWork { await $0.handleAtmosTransition(isAtmos: false) }
    }
  }

  // MARK: - Transitions & Adjustments

  private func handleAtmosTransition(isAtmos: Bool) async {
    // Writing `player:volume` on AMBEO hardware automatically unmutes the soundbar.
    // Wait for any active Stealth Rewind session to complete before adjusting volume.
    await waitForStealthRewind()

    // A later transition may have flipped the state while this one waited in the queue.
    guard !isShuttingDown, isAtmos == isAtmosActive, let client = clientProvider() else { return }

    if isAtmos {
      Logger.audio.info(
        "Dolby Atmos detected (CoreAudio: \(isCoreAudioAtmos), Soundbar: \(isSoundbarAtmos))"
      )
      let targetAmount = boostAmountProvider()
      if targetAmount > 0 && appliedAtmosBoost == 0 {
        let boost = Int(targetAmount)
        guard let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume()) else { return }
        let current = await client.state.volume
        guard !Task.isCancelled, isAtmosActive else { return }
        let change = VolumeAdjustment.change(
          from: current,
          delta: boost,
          min: entry.edit.flatMap { $0.min },
          max: entry.edit.flatMap { $0.max }
        )
        let newVol = change.newValue
        let actualBoost = change.appliedDelta

        guard await setBoostVolume(client, to: newVol, action: "apply") else { return }
        appliedAtmosBoost = actualBoost
        Logger.audio.info("Atmos Boost applied: \(current) → \(newVol) (+\(actualBoost)%)")
        await onShowOverlay()
      }
    } else {
      Logger.audio.info("Dolby Atmos ended, stereo playback active.")
      if appliedAtmosBoost > 0 {
        guard let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume()) else { return }
        let current = await client.state.volume
        guard !Task.isCancelled, !isAtmosActive else { return }
        let revertedBoost = appliedAtmosBoost
        let newVol = VolumeAdjustment.clamped(
          current - revertedBoost,
          min: entry.edit.flatMap { $0.min },
          max: entry.edit.flatMap { $0.max }
        )

        guard await setBoostVolume(client, to: newVol, action: "revert") else { return }
        appliedAtmosBoost = 0
        Logger.audio.info("Atmos Boost reverted: \(current) → \(newVol) (-\(revertedBoost)%)")
        await onShowOverlay()
      }
    }
  }

  func handleBoostAmountChanged(from oldAmount: Double, to newAmount: Double) {
    guard isAtmosActive else { return }

    enqueueAtmosWork { coordinator in
      await coordinator.waitForStealthRewind()
      guard !coordinator.isShuttingDown, coordinator.isAtmosActive,
        let client = coordinator.clientProvider()
      else { return }
      // Read the target at run time: several slider changes may be queued.
      let delta = Int(coordinator.boostAmountProvider()) - coordinator.appliedAtmosBoost
      guard delta != 0 else { return }
      guard let entry = await client.getEntry(for: AmbeoEndpoint.Player.Volume()) else { return }
      let current = await client.state.volume
      guard !Task.isCancelled, coordinator.isAtmosActive else { return }
      let change = VolumeAdjustment.change(
        from: current,
        delta: delta,
        min: entry.edit.flatMap { $0.min },
        max: entry.edit.flatMap { $0.max }
      )
      let newVol = change.newValue
      let actualDelta = change.appliedDelta

      guard await coordinator.setBoostVolume(client, to: newVol, action: "adjust") else { return }
      coordinator.appliedAtmosBoost = max(0, coordinator.appliedAtmosBoost + actualDelta)
      Logger.audio.info(
        "Atmos Boost adjusted: \(current) → \(newVol) (\(actualDelta >= 0 ? "+" : "")\(actualDelta)%)"
      )
      await coordinator.onShowOverlay()
    }
  }

  // MARK: - Cleanup (Disconnect / Sleep / Termination)

  /// Keep the per-device ledger if the device is unreachable; reconnect can retry safely.
  func revertOutstandingBoost(using client: AmbeoClient) async {
    let uid = connectedUid
    let boost = boostLedger.amount(for: uid)
    guard boost > 0 else { return }
    do {
      if try await client.removeVolumeBoost(boost, timeout: AmbeoClient.interactiveTimeout) {
        boostLedger.record(0, for: uid)
      }
    } catch {
      Logger.audio.warning(
        "Boost cleanup failed: \(error.localizedDescription). Preserving device ledger."
      )
    }
  }

  func cancelDeactivationAndWaitForTransition() async {
    atmosDeactivationTask?.cancel()
    atmosDeactivationTask = nil
    await atmosTransitionTask?.value
  }

  func revertBeforeSleep(using client: AmbeoClient?) async {
    await cancelDeactivationAndWaitForTransition()
    guard appliedAtmosBoost > 0, let client else { return }
    let boost = appliedAtmosBoost
    let current = await client.state.volume
    let newVol = VolumeAdjustment.clamped(
      current - boost,
      min: (await client.getEntry(for: AmbeoEndpoint.Player.Volume()))?.edit.flatMap { $0.min },
      max: nil
    )
    do {
      try await client.set(
        AmbeoEndpoint.Player.Volume(),
        valueJSON: "{\"type\":\"i32_\",\"i32_\":\(newVol)}",
        timeout: AmbeoClient.interactiveTimeout
      )
      appliedAtmosBoost = 0
      isAtmosActive = false
      isCoreAudioAtmos = false
      isSoundbarAtmos = false
      Logger.audio.info("Atmos Boost reverted before sleep: \(current) → \(newVol) (-\(boost)%)")
    } catch {
      Logger.audio.warning(
        "Failed to revert Atmos Boost before sleep: \(error.localizedDescription). Preserving boost state across wake."
      )
    }
  }
}
