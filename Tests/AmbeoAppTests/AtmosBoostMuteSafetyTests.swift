import Foundation
import Testing

@testable import AmbeoApp
@testable import AmbeoCore

/// The behaviour behind 🔴3: a volume write unmutes AMBEO hardware, so Atmos Boost must not write
/// while the user has muted the soundbar. This is the app-side logic that had no test target
/// before AppModel moved into a library.
@MainActor @Suite("Atmos Boost Mute Safety", .serialized) struct AtmosBoostMuteSafetyTests {
  private func makeModel(
    muted: Bool,
    volume: Int = 30,
    muteEndpointExists: Bool = true
  ) -> (AppModel, AmbeoClient, FakeSoundbarProtocol.Device) {
    let device = FakeSoundbarProtocol.Device()
    device.muted = muted
    device.volume = volume
    device.muteEndpointExists = muteEndpointExists
    // A unique host per test keeps the process-global URLProtocol registry collision-free.
    let host = "fake-ambeo-\(UUID().uuidString.prefix(8)).local"
    FakeSoundbarProtocol.install(device, forHost: host)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeSoundbarProtocol.self]
    let client = AmbeoClient(host: host, configuration: config)

    var settings = AppSettings()
    settings.atmosBoostAmount = 10
    let model = AppModel(settings: settings, autostart: false, volumeOverlay: RecordingOverlay())
    model.ambeoClient = client
    return (model, client, device)
  }

  @Test("A boost write is refused while the user is muted, and nothing reaches the device")
  func writeIsRefusedWhileMuted() async {
    let (model, client, device) = makeModel(muted: true)

    let applied = await model.setBoostVolume(client, to: 40, action: "apply")

    #expect(!applied)
    // The whole point: no volume write means the hardware stays muted.
    #expect(device.volumeWrites().isEmpty)
    // A refused write must not touch the ledger, or the revert would subtract a boost that was
    // never applied.
    #expect(model.appliedAtmosBoost == 0)
    #expect(model.deferredBoostReasonWhileMuted == "apply")
  }

  @Test("The same write goes through when the soundbar is not muted") func writeAppliesWhenUnmuted()
    async
  {
    let (model, client, device) = makeModel(muted: false)

    let applied = await model.setBoostVolume(client, to: 40, action: "apply")

    #expect(applied)
    #expect(device.volumeWrites() == [#"{"type":"i32_","i32_":40}"#])
    #expect(model.deferredBoostReasonWhileMuted == nil)
  }

  @Test("An unknown mute state counts as muted") func unknownMuteStateDefers() async {
    // Firmware that does not answer the mute endpoint leaves the state unknown. Deferring is
    // recoverable; silently unmuting the user is not.
    let (model, client, device) = makeModel(muted: false, muteEndpointExists: false)

    #expect(await model.isSoundbarMuted(client))

    let applied = await model.setBoostVolume(client, to: 40, action: "adjust")
    #expect(!applied)
    #expect(device.volumeWrites().isEmpty)
    #expect(model.deferredBoostReasonWhileMuted == "adjust")
  }

  @Test("A failed write is reported as refused so the ledger keeps the previous boost")
  func failedWriteKeepsLedger() async {
    let (model, client, _) = makeModel(muted: false)
    // Ledger entries are attributed to a connected soundbar; an empty uid is ignored by design.
    model.connectedUid = "mini-test"
    model.appliedAtmosBoost = 7

    // Drop the session so the volume write throws, the way an unreachable soundbar would.
    await client.shutdown()
    let applied = await model.setBoostVolume(client, to: 40, action: "apply")

    #expect(!applied)
    #expect(model.appliedAtmosBoost == 7)
  }
}
