import Foundation
import Testing

@testable import AmbeoCompanion
@testable import AmbeoCore

@MainActor @Suite("Atmos Boost Coordinator", .serialized) struct AtmosBoostCoordinatorTests {
  private func makeHarness(
    muted: Bool = false,
    volume: Int = 30,
    boostAmount: Double = 10,
    deactivationGrace: Duration = .milliseconds(40)
  ) -> (AtmosBoostCoordinator, AmbeoClient, FakeSoundbarProtocol.Device, UserDefaults, String) {
    let device = FakeSoundbarProtocol.Device()
    device.muted = muted
    device.volume = volume
    let host = "fake-ambeo-coord-\(UUID().uuidString.prefix(8)).local"
    FakeSoundbarProtocol.install(device, forHost: host)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeSoundbarProtocol.self]
    let client = AmbeoClient(host: host, configuration: config)

    let suiteName = "io.github.jhorology.AmbeoCompanion.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let ledger = AtmosBoostLedger(defaults: defaults, key: "ledger")

    let coordinator = AtmosBoostCoordinator(
      boostLedger: ledger,
      deactivationGrace: deactivationGrace,
      clientProvider: { client },
      boostAmountProvider: { boostAmount },
      cachedIsMutedProvider: { device.muted }
    )
    coordinator.assignConnectedDevice(uid: "ambeo-mini-1")
    return (coordinator, client, device, defaults, suiteName)
  }

  @Test("Applies boost on Atmos detection and reverts after deactivation grace period")
  func applyAndRevertCycle() async throws {
    let (coordinator, client, device, defaults, suiteName) = makeHarness(
      volume: 30,
      boostAmount: 12
    )
    defer { defaults.removePersistentDomain(forName: suiteName) }

    await client.register(AmbeoEndpoint.Player.Volume())
    await client.register(AmbeoEndpoint.Player.Mute())

    coordinator.evaluateAtmosState(coreAudioAtmos: true)
    #expect(coordinator.isAtmosActive)

    try await Task.sleep(for: .milliseconds(30))
    #expect(coordinator.appliedAtmosBoost == 12)
    #expect(device.volumeWrites() == [#"{"type":"i32_","i32_":42}"#])

    // Update simulated hardware volume to 42 before reverting
    device.volume = 42
    coordinator.evaluateAtmosState(coreAudioAtmos: false)
    // Still active inside the grace period
    #expect(coordinator.isAtmosActive)

    try await Task.sleep(for: .milliseconds(80))
    #expect(!coordinator.isAtmosActive)
    #expect(coordinator.appliedAtmosBoost == 0)
    #expect(device.volumeWrites().last == #"{"type":"i32_","i32_":30}"#)

    await client.shutdown()
  }

  @Test("Transient Atmos drop shorter than grace period cancels deactivation without reverting")
  func transientDropCancelsDeactivation() async throws {
    let (coordinator, client, device, defaults, suiteName) = makeHarness(
      volume: 25,
      boostAmount: 10,
      deactivationGrace: .milliseconds(80)
    )
    defer { defaults.removePersistentDomain(forName: suiteName) }

    await client.register(AmbeoEndpoint.Player.Volume())
    await client.register(AmbeoEndpoint.Player.Mute())

    coordinator.evaluateAtmosState(coreAudioAtmos: true)
    try await Task.sleep(for: .milliseconds(25))
    #expect(coordinator.appliedAtmosBoost == 10)
    #expect(device.volumeWrites().count == 1)

    // Brief drop followed by re-lock before 80ms expires
    coordinator.evaluateAtmosState(coreAudioAtmos: false)
    try await Task.sleep(for: .milliseconds(20))
    coordinator.evaluateAtmosState(coreAudioAtmos: true)
    try await Task.sleep(for: .milliseconds(90))

    #expect(coordinator.isAtmosActive)
    #expect(coordinator.appliedAtmosBoost == 10)
    // Only the initial apply write should have been sent (no revert or double-apply)
    #expect(device.volumeWrites().count == 1)

    await client.shutdown()
  }

  @Test("Deferred boost while muted replays when soundbar is unmuted") func deferredReplayOnUnmute()
    async throws
  {
    let (coordinator, client, device, defaults, suiteName) = makeHarness(
      muted: true,
      volume: 20,
      boostAmount: 15
    )
    defer { defaults.removePersistentDomain(forName: suiteName) }

    await client.register(AmbeoEndpoint.Player.Volume())

    coordinator.evaluateAtmosState(soundbarAtmos: true)
    try await Task.sleep(for: .milliseconds(30))

    // Refused while muted
    #expect(coordinator.appliedAtmosBoost == 0)
    #expect(coordinator.deferredBoostReasonWhileMuted == "apply")
    #expect(device.volumeWrites().isEmpty)

    // Unmute and replay
    device.muted = false
    try await client.set(AmbeoEndpoint.Player.Mute(), valueJSON: #"{"type":"bool_","bool_":false}"#)
    coordinator.replayDeferredVolumeWork(afterUnmute: "test unmute")
    try await Task.sleep(for: .milliseconds(30))

    #expect(coordinator.deferredBoostReasonWhileMuted == nil)
    #expect(coordinator.appliedAtmosBoost == 15)
    #expect(device.volumeWrites() == [#"{"type":"i32_","i32_":35}"#])

    await client.shutdown()
  }
}
