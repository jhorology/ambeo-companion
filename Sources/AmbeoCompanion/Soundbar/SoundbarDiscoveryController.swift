import AmbeoCore
import Foundation
import Logging
import Observation

/// Manages mDNS discovery for Sennheiser AMBEO soundbars, tracks the Local Network permission
/// inference grace window, and detects IP address changes on the selected soundbar.
@Observable @MainActor final class SoundbarDiscoveryController {
  static let discoveryGrace: Duration = .seconds(15)
  static let ipChangeDebounce: Duration = .seconds(3)

  var networkDevices: [SennheiserNetworkDevice] = []
  private(set) var discoveryStartedAt: ContinuousClock.Instant? = nil
  var discoveryGraceElapsed = false

  private var discoveryGeneration = 0
  private var discoveringAmbeoTask: Task<Void, Never>?
  private var ipChangeTask: Task<Void, Never>?

  func localNetworkStatus(hasClient: Bool) -> LocalNetworkPermissionStatus {
    if !networkDevices.isEmpty || hasClient { return .allowed }
    return discoveryGraceElapsed ? .nothingFound : .probing
  }

  /// The reconnect decision, kept as a pure function so it is testable. A missing client (nil
  /// host) is not an IP change, and an empty discovered address is not usable - both must not
  /// trigger the reconnect churn that previously dropped live sessions.
  nonisolated static func shouldReconnectForIPChange(host: String?, discoveredIP: String?) -> Bool {
    guard let host, !host.isEmpty, let discoveredIP, !discoveredIP.isEmpty else { return false }
    return host != discoveredIP
  }

  func host(for uid: String) -> String? { networkDevices.first(where: { $0.uuid == uid })?.ip }

  func startDiscovering(
    selectedUid: @escaping @MainActor () -> String,
    hasClient: @escaping @MainActor () -> Bool,
    currentHost: @escaping @MainActor () async -> String?,
    onReconnectNeeded: @escaping @MainActor () -> Void
  ) {
    discoveringAmbeoTask?.cancel()
    discoveryStartedAt = .now
    discoveryGraceElapsed = false
    discoveryGeneration += 1
    let generation = discoveryGeneration

    Task { [weak self] in
      try? await Task.sleep(for: Self.discoveryGrace)
      guard let self, !Task.isCancelled, generation == self.discoveryGeneration else { return }
      self.discoveryGraceElapsed = true
    }

    discoveringAmbeoTask = Task { [weak self] in
      for await devices in SennheiserDiscovery.browse() {
        guard !Task.isCancelled, let self else { return }
        self.networkDevices = devices
        Logger.network.debug("Discovered devices updated: \(devices.count) devices")
        let uid = selectedUid()
        guard !uid.isEmpty, let device = devices.first(where: { $0.uuid == uid }) else { continue }
        let host = await currentHost()
        if !hasClient() {
          // Selected device just appeared on the network
          onReconnectNeeded()
        } else if let host, host != device.ip {
          // The client is bound to the IP it was created with (e.g. a stale one from before
          // sleep). If the device moved (DHCP renewal, router reboot, network switch), the
          // current connection is dead even though the client itself is alive.
          self.debouncedReconnectIfIPChanged(
            selectedUid: selectedUid,
            currentHost: currentHost,
            onReconnectNeeded: onReconnectNeeded
          )
        }
      }
    }
  }

  /// Reconnects if the selected device's IP still differs from the client's host after a short
  /// grace period. Re-verifying against the latest discovery data before reconnecting avoids
  /// thrashing when mDNS briefly reports a transient address that then reverts.
  private func debouncedReconnectIfIPChanged(
    selectedUid: @escaping @MainActor () -> String,
    currentHost: @escaping @MainActor () async -> String?,
    onReconnectNeeded: @escaping @MainActor () -> Void
  ) {
    ipChangeTask?.cancel()
    ipChangeTask = Task { [weak self] in
      try? await Task.sleep(for: Self.ipChangeDebounce)
      guard !Task.isCancelled, let self else { return }
      let uid = selectedUid()
      let device = self.networkDevices.first(where: { $0.uuid == uid })
      let host = await currentHost()
      guard let discoveredIP = device?.ip,
        Self.shouldReconnectForIPChange(host: host, discoveredIP: discoveredIP)
      else { return }
      Logger.network.info(
        "Soundbar IP changed (\(host ?? "nil") -> \(discoveredIP)). Reconnecting."
      )
      onReconnectNeeded()
    }
  }

  func stopDiscovering() {
    discoveringAmbeoTask?.cancel()
    discoveringAmbeoTask = nil
    ipChangeTask?.cancel()
    ipChangeTask = nil
  }
}
