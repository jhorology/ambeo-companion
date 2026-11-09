import AmbeoCore
import Foundation
import Logging
import Observation

/// Manages the active `AmbeoClient` lifecycle, endpoint registration, generation tracking across
/// reconnections, and the observable `soundbarState` snapshot.
@Observable @MainActor final class SoundbarSession {
  var ambeoClient: AmbeoClient? = nil
  private(set) var disconnectingClient: AmbeoClient? = nil
  /// Snapshot of the soundbar state for SwiftUI observers such as the menu bar. `nil` until the
  /// client finishes its initial sync.
  var soundbarState: AmbeoState? = nil
  var maxIdleTime: Int = 0

  private(set) var clientGeneration = 0
  private var clientTask: Task<Void, Never>?

  var activeOrDisconnectingClient: AmbeoClient? { ambeoClient ?? disconnectingClient }

  /// Publishes the client's state right after a local write, without waiting for its echo event.
  func refreshSoundbarState(from client: AmbeoClient) async {
    let latestState = await client.state
    guard client === ambeoClient else { return }
    soundbarState = latestState
  }

  func reconnect(
    uid: String,
    host: String?,
    isShuttingDown: Bool,
    onCancelStealthRewind: @escaping @MainActor () async -> Void,
    onWaitPreviousAtmosTransition: @escaping @MainActor () async -> Void,
    onRevertBoostIfDeviceChanged: @escaping @MainActor (AmbeoClient, String) async -> Void,
    onClientAssigned: @escaping @MainActor (String) -> Void,
    onInitialSyncCompleted: @escaping @MainActor (AmbeoClient, AmbeoState) async -> Void
  ) {
    guard !isShuttingDown else { return }
    clientGeneration += 1
    let generation = clientGeneration

    let previousConnection = clientTask
    let previousClient = ambeoClient
    disconnectingClient = previousClient
    ambeoClient = nil
    soundbarState = nil

    clientTask = Task { [weak self] in
      await previousConnection?.value
      await onCancelStealthRewind()
      await previousClient?.stopObserving()
      await onWaitPreviousAtmosTransition()
      guard let self else {
        await previousClient?.shutdown()
        return
      }
      if self.disconnectingClient === previousClient { self.disconnectingClient = nil }
      if !Task.isCancelled, generation == self.clientGeneration, let previousClient {
        await onRevertBoostIfDeviceChanged(previousClient, uid)
      }
      // The previous connection is finished with (its boost state was reconciled above), so release
      // its session. Without this, every reconnect leaves a URLSession and connection pool behind.
      await previousClient?.shutdown()
      guard !Task.isCancelled, generation == self.clientGeneration else { return }
      guard !uid.isEmpty, let host else { return }

      onClientAssigned(uid)
      let client = AmbeoClient(host: host)
      self.ambeoClient = client

      await Self.registerAllEndpoints(on: client)

      guard !Task.isCancelled, generation == self.clientGeneration else {
        if self.ambeoClient === client { self.ambeoClient = nil }
        await client.shutdown()
        return
      }

      await client.startObserving()
      await client.markInitialSyncCompleted()

      guard !Task.isCancelled, generation == self.clientGeneration else {
        if self.ambeoClient === client { self.ambeoClient = nil }
        await client.shutdown()
        return
      }

      let initialState = await client.state
      guard generation == self.clientGeneration else { return }
      self.soundbarState = initialState
      await onInitialSyncCompleted(client, initialState)
    }
  }

  static func registerAllEndpoints(on client: AmbeoClient) async {
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
  }

  func cancelConnectionTask() { clientTask?.cancel() }

  func dropAndShutdownCurrentClient() async {
    let client = ambeoClient
    ambeoClient = nil
    clientGeneration += 1
    await client?.shutdown()
  }

  func waitForTermination() async -> AmbeoClient? {
    clientGeneration += 1
    await clientTask?.value
    return ambeoClient
  }
}
