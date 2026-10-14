import CoreAudio
import Foundation
import Logging

/// Coordinates the 6-step "Stealth Rewind" sequence when the Mac's physical output format changes
/// while `Music.app` is playing:
/// 1. Detect Mac sound output physical format switch
/// 2. Mute AMBEO
/// 3. Detect AMBEO sound input format switch (`imx8af:decoderAudioFormat`)
/// 4. Rewind `Music.app` playback position to `0` via Automation
/// 5. Wait a configurable settle delay (`settleDelay`) for the pre-seek buffer to drain
/// 6. Unmute AMBEO (with a safety timeout so the soundbar is never left muted)
@MainActor
public final class StealthRewindCoordinator {
  public static let defaultSettleDelay: Duration = .milliseconds(250)
  public static let defaultMuteTimeout: Duration = .seconds(5)

  private enum Phase: Equatable {
    case idle
    case waitingForInitialLock
    case rewindingAndSettling
  }

  public var settleDelay: Duration
  public var muteTimeout: Duration

  private let musicPlayer: any MusicPlayerControlling
  private let isMutedProvider: @MainActor () async -> Bool
  private let setMute: @MainActor (Bool) async throws -> Void
  private let currentSoundbarFormatProvider: @MainActor () async -> AmbeoAudioFormat?

  private var lastObservedFormat: (deviceID: AudioDeviceID, format: AudioPhysicalFormat)?
  private var sessionID: Int = 0
  private var phase: Phase = .idle
  public var isSessionActive: Bool { phase != .idle }
  public private(set) var isSuppressingMuteOSD: Bool = false

  private var activeTargetIsAtmos: Bool = false
  private var shouldUnmuteOnCompletion: Bool = false
  private var sessionStartInstant: ContinuousClock.Instant?
  private var rewindInstant: ContinuousClock.Instant?
  private var actionTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var clearOSDSuppressionTask: Task<Void, Never>?
  private var sessionWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    settleDelay: Duration = StealthRewindCoordinator.defaultSettleDelay,
    muteTimeout: Duration = StealthRewindCoordinator.defaultMuteTimeout,
    musicPlayer: any MusicPlayerControlling = MusicPlayerController.shared,
    isMutedProvider: @escaping @MainActor () async -> Bool,
    setMute: @escaping @MainActor (Bool) async throws -> Void,
    currentSoundbarFormatProvider: @escaping @MainActor () async -> AmbeoAudioFormat?
  ) {
    self.settleDelay = settleDelay
    self.muteTimeout = muteTimeout
    self.musicPlayer = musicPlayer
    self.isMutedProvider = isMutedProvider
    self.setMute = setMute
    self.currentSoundbarFormatProvider = currentSoundbarFormatProvider
  }

  /// Resets the tracked physical format so the next emission from a newly monitored stream
  /// is treated as the baseline format rather than a transition.
  public func resetObservedFormat() {
    lastObservedFormat = nil
  }

  /// Suspends the caller while a Stealth Rewind session is actively muting the soundbar.
  /// Used by Atmos Boost so `player:volume` writes do not prematurely unmute the AMBEO hardware.
  public func waitForActiveSession() async {
    guard isSessionActive else { return }
    await withCheckedContinuation { continuation in
      sessionWaiters.append(continuation)
    }
  }

  /// Step 1: Handles a physical format emission from `AudioDeviceMonitor.formatStream`.
  public func handleCoreAudioFormatChange(
    _ format: AudioPhysicalFormat?,
    deviceID: AudioDeviceID,
    isEnabled: Bool,
    isClientConnected: Bool
  ) async {
    guard let format else { return }
    guard let previous = lastObservedFormat, previous.deviceID == deviceID else {
      lastObservedFormat = (deviceID: deviceID, format: format)
      return
    }
    lastObservedFormat = (deviceID: deviceID, format: format)
    guard previous.format != format else { return }

    guard isEnabled, isClientConnected else { return }

    let targetIsAtmos = format.isAtmosOrMultichannel

    // If a session is already in progress (e.g. fallback format applied right after Atmos -> Stereo,
    // or rapid track skipping cc+3 -> lpcm -> cc+3), update the target and extend the timeout
    // while preserving the initial mute state.
    if isSessionActive {
      let targetChanged = (activeTargetIsAtmos != targetIsAtmos)
      activeTargetIsAtmos = targetIsAtmos
      if targetChanged {
        actionTask?.cancel()
        actionTask = nil
        phase = .waitingForInitialLock
      }
      startTimeoutTask(for: sessionID)
      Logger.audio.debug(
        "Stealth Rewind: Updated active session for format \(format.displayName) (targetAtmos=\(targetIsAtmos), \(elapsedSummary()))"
      )
      return
    }

    // Precondition: Music.app must be running and currently playing.
    guard musicPlayer.isRunning(), await musicPlayer.isPlaying() else {
      Logger.audio.debug("Stealth Rewind skipped: Music.app is not running or not playing.")
      return
    }

    guard !isSessionActive else { return }

    sessionID += 1
    let currentID = sessionID
    phase = .waitingForInitialLock
    activeTargetIsAtmos = targetIsAtmos
    sessionStartInstant = ContinuousClock.now
    rewindInstant = nil
    clearOSDSuppressionTask?.cancel()
    isSuppressingMuteOSD = true

    let wasAlreadyMuted = await isMutedProvider()
    guard isSessionActive, sessionID == currentID else { return }
    shouldUnmuteOnCompletion = !wasAlreadyMuted

    Logger.audio.info(
      "Stealth Rewind [1/6]: Detected Mac output format switch (\(previous.format.displayName) -> \(format.displayName)) while Music.app is playing."
    )

    // Step 2: Mute AMBEO
    let muteStart = ContinuousClock.now
    do {
      try await setMute(true)
      let muteRpcMs = muteStart.duration(to: ContinuousClock.now).millisecondsString
      Logger.audio.info(
        "Stealth Rewind [2/6]: Muted AMBEO (wasAlreadyMuted=\(wasAlreadyMuted), rpc=\(muteRpcMs), \(elapsedSummary()), timeout=\(muteTimeout))."
      )
    } catch {
      Logger.audio.warning(
        "Stealth Rewind [2/6]: Failed to mute AMBEO (\(error.localizedDescription)). Aborting."
      )
      shouldUnmuteOnCompletion = false
      finishSession(id: currentID)
      return
    }

    guard isSessionActive, sessionID == currentID else { return }

    startTimeoutTask(for: currentID)

    // If switching between Atmos and Stereo and the soundbar already reported the new locked format
    // just before CoreAudio's callback arrived, begin Step 4 rewind immediately; otherwise wait for Step 3.
    let formatClassChanged = (previous.format.isAtmosOrMultichannel != targetIsAtmos)
    if formatClassChanged,
      let currentSBFormat = await currentSoundbarFormatProvider(),
      isSessionActive, sessionID == currentID,
      phase == .waitingForInitialLock,
      currentSBFormat.matchesTransitionTarget(isAtmosOrMultichannel: targetIsAtmos)
    {
      beginRewindAndSettlePhase(for: currentID, format: currentSBFormat)
    } else if phase == .waitingForInitialLock {
      Logger.audio.info(
        "Stealth Rewind [3/6]: Waiting for AMBEO input format switch (expecting isAtmos=\(targetIsAtmos))..."
      )
    }
  }

  /// Step 3: Handles `imx8af:decoderAudioFormat` updates from the AMBEO soundbar.
  public func handleSoundbarFormatChange(_ format: AmbeoAudioFormat?) {
    if isSessionActive || rewindInstant != nil {
      Logger.audio.debug(
        "Stealth Rewind telemetry: AMBEO decoderAudioFormat -> codec=\(format?.codec ?? "none"), channels=\(format?.channels ?? 0), isAtmos=\(format?.isAtmos ?? false), phase=\(String(describing: phase)) (\(elapsedSummary()))"
      )
    }
    guard isSessionActive, phase == .waitingForInitialLock else { return }
    guard let format, format.matchesTransitionTarget(isAtmosOrMultichannel: activeTargetIsAtmos)
    else { return }
    beginRewindAndSettlePhase(for: sessionID, format: format)
  }

  /// Cancels any active Stealth Rewind session and unmutes the soundbar if Stealth Rewind muted it.
  public func cancelAndUnmuteIfNeeded(reason: String) async {
    guard isSessionActive else { return }
    let currentID = sessionID
    actionTask?.cancel()
    actionTask = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    Logger.audio.info("Stealth Rewind: Cancelling active session (\(reason), \(elapsedSummary())).")
    await unmuteIfNeeded(stepLabel: "cancel:\(reason)")
    finishSession(id: currentID)
  }

  // MARK: - Private Steps 4–6 & Timeout

  private func beginRewindAndSettlePhase(for id: Int, format: AmbeoAudioFormat) {
    actionTask?.cancel()
    phase = .rewindingAndSettling
    Logger.audio.info(
      "Stealth Rewind [3/6]: Detected AMBEO input format switch (codec=\(format.codec ?? "unknown"), channels=\(format.channels ?? 0), isAtmos=\(format.isAtmos), \(elapsedSummary()))."
    )

    actionTask = Task { @MainActor [weak self] in
      guard let self, self.isSessionActive, self.sessionID == id else { return }

      // Step 4: Rewind Music.app to player position 0 while AMBEO is still muted
      let rewound = await self.musicPlayer.rewindToStart()
      guard self.isSessionActive, self.sessionID == id else { return }
      self.rewindInstant = ContinuousClock.now

      Logger.audio.info(
        "Stealth Rewind [4/6]: Music.app player position -> 0 (success=\(rewound), \(self.elapsedSummary()))."
      )

      // Step 5: Wait settleDelay for the pre-seek buffer to drain before unmuting
      let delay = self.settleDelay
      Logger.audio.info(
        "Stealth Rewind [5/6]: Waiting \(delay) before unmuting AMBEO..."
      )
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard self.isSessionActive, self.sessionID == id else { return }

      await self.completeAndUnmute(for: id)
    }
  }

  private func completeAndUnmute(for id: Int) async {
    guard isSessionActive, sessionID == id else { return }
    timeoutTask?.cancel()
    timeoutTask = nil
    await unmuteIfNeeded(stepLabel: "6/6")
    finishSession(id: id)
  }

  private func startTimeoutTask(for id: Int) {
    timeoutTask?.cancel()
    let timeout = muteTimeout
    timeoutTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      guard let self, self.isSessionActive, self.sessionID == id else { return }
      self.actionTask?.cancel()
      self.actionTask = nil
      Logger.audio.warning(
        "Stealth Rewind: Mute timeout (\(timeout)) expired waiting for AMBEO format switch (\(self.elapsedSummary())). Unmuting AMBEO."
      )
      await self.unmuteIfNeeded(stepLabel: "timeout")
      self.finishSession(id: id)
    }
  }

  private func unmuteIfNeeded(stepLabel: String) async {
    guard shouldUnmuteOnCompletion else {
      Logger.audio.debug(
        "Stealth Rewind [\(stepLabel)]: Skipping unmute because AMBEO was already muted before transition."
      )
      return
    }
    shouldUnmuteOnCompletion = false
    let unmuteStart = ContinuousClock.now
    do {
      try await setMute(false)
      let unmuteRpcMs = unmuteStart.duration(to: ContinuousClock.now).millisecondsString
      Logger.audio.info(
        "Stealth Rewind [\(stepLabel)]: Unmuted AMBEO (rpc=\(unmuteRpcMs), \(elapsedSummary()))."
      )
    } catch {
      Logger.audio.warning(
        "Stealth Rewind [\(stepLabel)]: Failed to unmute AMBEO (\(error.localizedDescription))."
      )
    }
  }

  private func finishSession(id: Int) {
    guard sessionID == id else { return }
    actionTask?.cancel()
    actionTask = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    phase = .idle
    shouldUnmuteOnCompletion = false

    let waiters = sessionWaiters
    sessionWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }

    clearOSDSuppressionTask?.cancel()
    clearOSDSuppressionTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled, let self, !self.isSessionActive else { return }
      self.isSuppressingMuteOSD = false
      try? await Task.sleep(for: .milliseconds(1500))
      guard !Task.isCancelled, !self.isSessionActive else { return }
      self.sessionStartInstant = nil
      self.rewindInstant = nil
    }
  }

  private func elapsedSummary() -> String {
    let now = ContinuousClock.now
    var parts: [String] = []
    if let start = sessionStartInstant {
      parts.append("+\(start.duration(to: now).millisecondsString) from start")
    }
    if let rewind = rewindInstant {
      parts.append("+\(rewind.duration(to: now).millisecondsString) from rewind")
    }
    return parts.isEmpty ? "t=0ms" : parts.joined(separator: ", ")
  }
}

extension AmbeoAudioFormat {
  /// Whether the soundbar decoder is locked onto an active audio stream
  /// (as opposed to `codec: "none"` / `channels: 0` while renegotiating HDMI/eARC).
  var isLocked: Bool {
    guard let codec = codec?.trimmingCharacters(in: .whitespacesAndNewlines),
      !codec.isEmpty,
      codec.caseInsensitiveCompare("none") != .orderedSame
    else { return false }
    if let channels, channels <= 0 {
      return false
    }
    return true
  }

  func matchesTransitionTarget(isAtmosOrMultichannel: Bool) -> Bool {
    guard isLocked else { return false }
    return isAtmos == isAtmosOrMultichannel
  }
}
