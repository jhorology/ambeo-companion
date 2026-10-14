import CoreAudio
import Foundation
import Testing

@testable import AmbeoCore

@MainActor
private final class MockMusicPlayer: MusicPlayerControlling, @unchecked Sendable {
  var running: Bool = true
  var playing: Bool = true
  var permission: MusicAutomationPermissionStatus = .granted
  var rewindCallCount: Int = 0
  var onRewind: (() -> Void)?

  nonisolated func isRunning() -> Bool {
    MainActor.assumeIsolated { running }
  }

  nonisolated func permissionStatus(askUserIfNeeded: Bool) -> MusicAutomationPermissionStatus {
    MainActor.assumeIsolated { permission }
  }

  func isPlaying() async -> Bool {
    running && playing && permission == .granted
  }

  @discardableResult
  func rewindToStart() async -> Bool {
    rewindCallCount += 1
    onRewind?()
    return true
  }
}

private func makePhysicalFormat(
  sampleRate: Double,
  channels: UInt32,
  bitDepth: UInt32,
  formatID: AudioFormatID
) -> AudioPhysicalFormat {
  AudioPhysicalFormat(
    channels: channels,
    bitDepth: bitDepth,
    sampleRate: sampleRate,
    formatID: formatID
  )
}

@MainActor
private final class MuteRecoveryState {
  var muted = false
  var available = true
  var failures = 0
  var attempts = 0
  var events: [Bool] = []
  var pendingUnmute: CheckedContinuation<Void, Never>?
  var blockUnmute = false
  var repeatedCancelStarted = false

  func setMute(_ value: Bool) async throws {
    if !value {
      attempts += 1
      if failures > 0 {
        failures -= 1
        throw URLError(.timedOut)
      }
      if blockUnmute {
        await withCheckedContinuation { pendingUnmute = $0 }
      }
    }
    muted = value
    events.append(value)
  }

  func releaseUnmute() {
    blockUnmute = false
    pendingUnmute?.resume()
    pendingUnmute = nil
  }
}

@Suite("Stealth Rewind Tests")
struct StealthRewindTests {
  private static let stereoLPCM = makePhysicalFormat(
    sampleRate: 48_000,
    channels: 2,
    bitDepth: 24,
    formatID: kAudioFormatLinearPCM
  )
  private static let atmosEAC3 = makePhysicalFormat(
    sampleRate: 192_000,
    channels: 2,
    bitDepth: 16,
    formatID: 0x6363_2B33  // 'cc+3'
  )

  @Test("AmbeoAudioFormat lock and transition target matching")
  func audioFormatLockAndMatching() {
    let unlocked = AmbeoAudioFormat(codec: "none", channels: 0, sampleRate: 0)
    #expect(!unlocked.isLocked)
    #expect(!unlocked.isAtmos)
    #expect(!unlocked.matchesTransitionTarget(isAtmosOrMultichannel: false))
    #expect(!unlocked.matchesTransitionTarget(isAtmosOrMultichannel: true))

    let stereoPCM = AmbeoAudioFormat(codec: "pcm", channels: 2, sampleRate: 48_000)
    #expect(stereoPCM.isLocked)
    #expect(!stereoPCM.isAtmos)
    #expect(stereoPCM.matchesTransitionTarget(isAtmosOrMultichannel: false))
    #expect(!stereoPCM.matchesTransitionTarget(isAtmosOrMultichannel: true))

    let dolbyAtmos = AmbeoAudioFormat(
      codec: "Dolby Digital Plus - Dolby Atmos",
      channels: 12,
      sampleRate: 48_000
    )
    #expect(dolbyAtmos.isLocked)
    #expect(dolbyAtmos.isAtmos)
    #expect(dolbyAtmos.matchesTransitionTarget(isAtmosOrMultichannel: true))
    #expect(!dolbyAtmos.matchesTransitionTarget(isAtmosOrMultichannel: false))
  }

  @Test("Executes 6-step Stealth Rewind sequence in order when Music.app is playing")
  @MainActor
  func fullStealthRewindSequence() async throws {
    let music = MockMusicPlayer()
    var events: [String] = []
    var isMuted = false
    let soundbarFormat: AmbeoAudioFormat? = AmbeoAudioFormat(
      codec: "pcm",
      channels: 2,
      sampleRate: 48_000
    )
    music.onRewind = { events.append("rewind") }

    let coordinator = StealthRewindCoordinator(
      settleDelay: .milliseconds(30),
      muteTimeout: .seconds(1),
      musicPlayer: music,
      isMutedProvider: { isMuted },
      setMute: { muted in
        isMuted = muted
        events.append("mute(\(muted))")
      },
      currentSoundbarFormatProvider: { soundbarFormat }
    )

    let deviceID: AudioDeviceID = 42

    // Initial stream emission establishes baseline without triggering rewind
    await coordinator.handleCoreAudioFormatChange(
      Self.stereoLPCM,
      deviceID: deviceID,
      isEnabled: true,
      isClientConnected: true
    )
    #expect(!coordinator.isSessionActive)
    #expect(events.isEmpty)

    // Step 1: CoreAudio switches from Stereo LPCM to Dolby Atmos
    await coordinator.handleCoreAudioFormatChange(
      Self.atmosEAC3,
      deviceID: deviceID,
      isEnabled: true,
      isClientConnected: true
    )
    // Step 2: AMBEO is immediately muted
    #expect(coordinator.isSessionActive)
    #expect(events == ["mute(true)"])

    // Step 3: AMBEO reports Atmos input format lock -> Step 4 rewind -> Step 5 settle -> Step 6 unmute
    let atmosFormat = AmbeoAudioFormat(
      codec: "Dolby Digital Plus - Dolby Atmos",
      channels: 12,
      sampleRate: 48_000
    )
    coordinator.handleSoundbarFormatChange(atmosFormat)

    await coordinator.waitForActiveSession()

    #expect(!coordinator.isSessionActive)
    #expect(!isMuted)
    #expect(music.rewindCallCount == 1)
    #expect(events == ["mute(true)", "rewind", "mute(false)"])
  }

  @Test("Enforces mute timeout and unmutes AMBEO if soundbar format switch never arrives")
  @MainActor
  func muteTimeoutUnmutesSoundbar() async throws {
    let music = MockMusicPlayer()
    var events: [String] = []
    var isMuted = false
    let soundbarFormat: AmbeoAudioFormat? = AmbeoAudioFormat(
      codec: "pcm",
      channels: 2,
      sampleRate: 48_000
    )

    let coordinator = StealthRewindCoordinator(
      settleDelay: .milliseconds(50),
      muteTimeout: .milliseconds(80),
      musicPlayer: music,
      isMutedProvider: { isMuted },
      setMute: { muted in
        isMuted = muted
        events.append("mute(\(muted))")
      },
      currentSoundbarFormatProvider: { soundbarFormat }
    )

    let deviceID: AudioDeviceID = 42
    await coordinator.handleCoreAudioFormatChange(
      Self.stereoLPCM,
      deviceID: deviceID,
      isEnabled: true,
      isClientConnected: true
    )
    await coordinator.handleCoreAudioFormatChange(
      Self.atmosEAC3,
      deviceID: deviceID,
      isEnabled: true,
      isClientConnected: true
    )
    #expect(coordinator.isSessionActive)
    #expect(isMuted)

    // Do not send soundbar format change; wait for timeout to expire
    await coordinator.waitForActiveSession()

    #expect(!coordinator.isSessionActive)
    #expect(!isMuted)
    #expect(music.rewindCallCount == 0)
    #expect(events == ["mute(true)", "mute(false)"])
  }

  @Test("Skips Stealth Rewind when Music.app is not playing or not running")
  @MainActor
  func skipsWhenMusicNotPlaying() async {
    let music = MockMusicPlayer()
    music.playing = false
    var muteCalls = 0

    let coordinator = StealthRewindCoordinator(
      settleDelay: .milliseconds(20),
      muteTimeout: .milliseconds(100),
      musicPlayer: music,
      isMutedProvider: { false },
      setMute: { _ in muteCalls += 1 },
      currentSoundbarFormatProvider: { nil }
    )

    let deviceID: AudioDeviceID = 42
    await coordinator.handleCoreAudioFormatChange(
      Self.stereoLPCM,
      deviceID: deviceID,
      isEnabled: true,
      isClientConnected: true
    )
    await coordinator.handleCoreAudioFormatChange(
      Self.atmosEAC3,
      deviceID: deviceID,
      isEnabled: true,
      isClientConnected: true
    )

    #expect(!coordinator.isSessionActive)
    #expect(muteCalls == 0)
    #expect(music.rewindCallCount == 0)
  }

  @Test("Unmutes AMBEO safely even if Automation permission is revoked mid-session")
  @MainActor
  func permissionRevokedMidSessionStillUnmutes() async throws {
    let music = MockMusicPlayer()
    var events: [String] = []
    var isMuted = false
    let soundbarFormat: AmbeoAudioFormat? = AmbeoAudioFormat(
      codec: "pcm",
      channels: 2,
      sampleRate: 48_000
    )

    let coordinator = StealthRewindCoordinator(
      settleDelay: .milliseconds(30),
      muteTimeout: .seconds(1),
      musicPlayer: music,
      isMutedProvider: { isMuted },
      setMute: { muted in
        isMuted = muted
        events.append("mute(\(muted))")
      },
      currentSoundbarFormatProvider: { soundbarFormat }
    )

    let deviceID: AudioDeviceID = 42
    await coordinator.handleCoreAudioFormatChange(
      Self.stereoLPCM,
      deviceID: deviceID,
      isEnabled: true,
      isClientConnected: true
    )
    await coordinator.handleCoreAudioFormatChange(
      Self.atmosEAC3,
      deviceID: deviceID,
      isEnabled: true,
      isClientConnected: true
    )
    #expect(coordinator.isSessionActive)
    #expect(isMuted)

    // User turns off Automation permission in System Settings while soundbar is muted
    music.permission = .denied
    await coordinator.cancelAndUnmuteIfNeeded(reason: "Music.app Automation permission denied")

    #expect(!coordinator.isSessionActive)
    #expect(!isMuted)
    #expect(events == ["mute(true)", "mute(false)"])

    // Subsequent format switches while permission is denied must not mute AMBEO
    await coordinator.handleCoreAudioFormatChange(
      Self.stereoLPCM,
      deviceID: deviceID,
      isEnabled: true,
      isClientConnected: true
    )
    #expect(!coordinator.isSessionActive)
    #expect(!isMuted)
    #expect(events == ["mute(true)", "mute(false)"])
  }

  @Test("Multichannel PCM and non-Atmos Dolby formats match the multichannel transition target")
  func multichannelFormatsMatchTarget() {
    let pcm8ch = AmbeoAudioFormat(codec: "pcm", channels: 8, sampleRate: 48_000)
    #expect(pcm8ch.matchesTransitionTarget(isAtmosOrMultichannel: true))
    #expect(!pcm8ch.matchesTransitionTarget(isAtmosOrMultichannel: false))

    let ddp51 = AmbeoAudioFormat(codec: "Dolby Digital Plus", channels: 6, sampleRate: 48_000)
    #expect(ddp51.matchesTransitionTarget(isAtmosOrMultichannel: true))

    let ddp20 = AmbeoAudioFormat(codec: "Dolby Digital Plus", channels: 2, sampleRate: 48_000)
    #expect(ddp20.matchesTransitionTarget(isAtmosOrMultichannel: true))

    let pcm2ch = AmbeoAudioFormat(codec: "pcm", channels: 2, sampleRate: 48_000)
    #expect(!pcm2ch.matchesTransitionTarget(isAtmosOrMultichannel: true))
  }

  @Test("Cancelling while the mute request is in flight leaves AMBEO unmuted")
  @MainActor
  func cancelDuringInFlightMuteUnmutesAfterMuteLands() async throws {
    let music = MockMusicPlayer()
    var events: [String] = []
    var isMuted = false
    var muteRequested = false

    let coordinator = StealthRewindCoordinator(
      settleDelay: .milliseconds(10),
      muteTimeout: .milliseconds(100),
      musicPlayer: music,
      isMutedProvider: { isMuted },
      setMute: { muted in
        if muted {
          // Simulate a slow mute RPC so the cancel's unmute would otherwise land first.
          muteRequested = true
          try await Task.sleep(for: .milliseconds(50))
        }
        isMuted = muted
        events.append("mute(\(muted))")
      },
      currentSoundbarFormatProvider: { nil }
    )

    let deviceID: AudioDeviceID = 42
    await coordinator.handleCoreAudioFormatChange(
      Self.stereoLPCM,
      deviceID: deviceID,
      isEnabled: true,
      isClientConnected: true
    )
    let transition = Task { @MainActor in
      await coordinator.handleCoreAudioFormatChange(
        Self.atmosEAC3,
        deviceID: deviceID,
        isEnabled: true,
        isClientConnected: true
      )
    }
    while !muteRequested { await Task.yield() }

    await coordinator.cancelAndUnmuteIfNeeded(reason: "disabled in settings")
    await transition.value

    #expect(!coordinator.isSessionActive)
    #expect(!isMuted)
    #expect(events == ["mute(true)", "mute(false)"])

    // The resumed transition must not have armed a timeout or rewind.
    try await Task.sleep(for: .milliseconds(150))
    #expect(events == ["mute(true)", "mute(false)"])
    #expect(music.rewindCallCount == 0)
  }

  @Test("A failed unmute is kept and retried after reconnect")
  @MainActor
  func failedUnmuteIsRetried() async throws {
    struct RPCError: Error {}
    let music = MockMusicPlayer()
    var isMuted = false
    var unmuteFailures = 1

    let coordinator = StealthRewindCoordinator(
      settleDelay: .milliseconds(10),
      muteTimeout: .seconds(1),
      musicPlayer: music,
      isMutedProvider: { isMuted },
      setMute: { muted in
        if !muted, unmuteFailures > 0 {
          unmuteFailures -= 1
          throw RPCError()
        }
        isMuted = muted
      },
      currentSoundbarFormatProvider: { nil }
    )

    let deviceID: AudioDeviceID = 42
    await coordinator.handleCoreAudioFormatChange(
      Self.stereoLPCM,
      deviceID: deviceID,
      isEnabled: true,
      isClientConnected: true
    )
    await coordinator.handleCoreAudioFormatChange(
      Self.atmosEAC3,
      deviceID: deviceID,
      isEnabled: true,
      isClientConnected: true
    )
    #expect(isMuted)

    await coordinator.cancelAndUnmuteIfNeeded(reason: "client reconnect")
    #expect(!coordinator.isSessionActive)
    #expect(isMuted)

    await coordinator.retryPendingUnmute(reason: "client connected")
    #expect(!isMuted)
  }

  @Test("An unavailable mute state preserves recovery until a later successful read")
  @MainActor
  func unavailableMuteStatePreservesPendingUnmute() async {
    let state = MuteRecoveryState()
    state.failures = 1
    let coordinator = StealthRewindCoordinator(
      musicPlayer: MockMusicPlayer(),
      isMutedProvider: { state.available ? state.muted : nil },
      setMute: { try await state.setMute($0) },
      currentSoundbarFormatProvider: { nil }
    )
    await coordinator.handleCoreAudioFormatChange(
      Self.stereoLPCM,
      deviceID: 42,
      isEnabled: true,
      isClientConnected: true
    )
    await coordinator.handleCoreAudioFormatChange(
      Self.atmosEAC3,
      deviceID: 42,
      isEnabled: true,
      isClientConnected: true
    )
    await coordinator.cancelAndUnmuteIfNeeded(reason: "connection lost")
    #expect(state.muted)
    #expect(state.attempts == 1)

    state.available = false
    await coordinator.retryPendingUnmute(reason: "mute fetch failed")
    #expect(state.muted)
    #expect(state.attempts == 1)
    #expect(!coordinator.isSessionActive)

    state.available = true
    await coordinator.retryPendingUnmute(reason: "mute state recovered")
    #expect(!state.muted)
    #expect(state.attempts == 2)
  }

  @Test("An unavailable initial mute state never mutes the soundbar")
  @MainActor
  func unavailableInitialMuteStateSkipsSession() async {
    let state = MuteRecoveryState()
    let coordinator = StealthRewindCoordinator(
      musicPlayer: MockMusicPlayer(),
      isMutedProvider: { nil },
      setMute: { try await state.setMute($0) },
      currentSoundbarFormatProvider: { nil }
    )
    await coordinator.handleCoreAudioFormatChange(
      Self.stereoLPCM,
      deviceID: 42,
      isEnabled: true,
      isClientConnected: true
    )
    await coordinator.handleCoreAudioFormatChange(
      Self.atmosEAC3,
      deviceID: 42,
      isEnabled: true,
      isClientConnected: true
    )
    #expect(state.events.isEmpty)
    #expect(!coordinator.isSessionActive)
  }

  @Test("A confirmed unmuted state clears recovery without changing a later user mute")
  @MainActor
  func confirmedUnmutedStateClearsRecovery() async {
    let state = MuteRecoveryState()
    state.failures = 1
    let coordinator = StealthRewindCoordinator(
      musicPlayer: MockMusicPlayer(),
      isMutedProvider: { state.muted },
      setMute: { try await state.setMute($0) },
      currentSoundbarFormatProvider: { nil }
    )
    await coordinator.handleCoreAudioFormatChange(
      Self.stereoLPCM,
      deviceID: 42,
      isEnabled: true,
      isClientConnected: true
    )
    await coordinator.handleCoreAudioFormatChange(
      Self.atmosEAC3,
      deviceID: 42,
      isEnabled: true,
      isClientConnected: true
    )
    await coordinator.cancelAndUnmuteIfNeeded(reason: "connection lost")
    state.muted = false
    await coordinator.retryPendingUnmute(reason: "already unmuted")
    #expect(state.attempts == 1)
    state.muted = true
    await coordinator.retryPendingUnmute(reason: "user muted later")
    #expect(state.attempts == 1)
    #expect(state.muted)
  }

  @Test(
    "Cleanup finishes before the next transition and concurrent cancels share one unmute",
    arguments: ["cancel", "complete", "timeout", "retry"]
  )
  @MainActor
  func cleanupSerializesNextTransition(path: String) async {
    let state = MuteRecoveryState()
    let coordinator = StealthRewindCoordinator(
      settleDelay: .zero,
      muteTimeout: path == "timeout" ? .milliseconds(30) : .seconds(5),
      musicPlayer: MockMusicPlayer(),
      isMutedProvider: { state.muted },
      setMute: { try await state.setMute($0) },
      currentSoundbarFormatProvider: { nil }
    )
    await coordinator.handleCoreAudioFormatChange(
      Self.stereoLPCM,
      deviceID: 42,
      isEnabled: true,
      isClientConnected: true
    )
    await coordinator.handleCoreAudioFormatChange(
      Self.atmosEAC3,
      deviceID: 42,
      isEnabled: true,
      isClientConnected: true
    )
    if path == "retry" {
      state.failures = 1
      await coordinator.cancelAndUnmuteIfNeeded(reason: "connection lost")
    }
    state.blockUnmute = true
    let cleanup = Task { @MainActor in
      switch path {
      case "complete":
        coordinator.handleSoundbarFormatChange(
          AmbeoAudioFormat(codec: "Dolby Atmos", channels: 12, sampleRate: 48_000)
        )
        await coordinator.waitForActiveSession()
      case "timeout":
        await coordinator.waitForActiveSession()
      case "retry":
        await coordinator.retryPendingUnmute(reason: "client connected")
      default:
        await coordinator.cancelAndUnmuteIfNeeded(reason: "disabled")
      }
    }
    while state.pendingUnmute == nil { await Task.yield() }
    #expect(coordinator.isSessionActive)
    let repeatedCancel = Task {
      state.repeatedCancelStarted = true
      await coordinator.cancelAndUnmuteIfNeeded(reason: "second cancel")
    }
    while !state.repeatedCancelStarted { await Task.yield() }
    let nextTransition = Task {
      await coordinator.handleCoreAudioFormatChange(
        Self.stereoLPCM,
        deviceID: 42,
        isEnabled: true,
        isClientConnected: true
      )
    }
    await Task.yield()
    #expect(state.events == [true])
    state.releaseUnmute()
    await cleanup.value
    await repeatedCancel.value
    await nextTransition.value
    #expect(state.events == [true, false, true])
    #expect(coordinator.isSessionActive)
    #expect(state.muted)
    await coordinator.cancelAndUnmuteIfNeeded(reason: "test cleanup")
    #expect(state.events == [true, false, true, false])
    #expect(!state.muted)
  }
}
