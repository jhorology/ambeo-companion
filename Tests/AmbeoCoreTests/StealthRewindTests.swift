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
    var soundbarFormat: AmbeoAudioFormat? = AmbeoAudioFormat(
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
    soundbarFormat = atmosFormat
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
}
