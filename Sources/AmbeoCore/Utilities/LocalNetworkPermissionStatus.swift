import Foundation

/// macOS has no public API for the Local Network permission, so its status is inferred from what
/// mDNS discovery produced. `allowed` is claimed only once browsing demonstrably worked; a silent
/// failure is reported as "No soundbar found" rather than asserting a denial.
public enum LocalNetworkPermissionStatus: Equatable, Sendable {
  case allowed
  case probing
  case nothingFound

  /// `grace` covers launch, wake and network switches, where an empty result list is normal.
  public init(
    deviceCount: Int,
    hasClient: Bool,
    startedAt: ContinuousClock.Instant?,
    grace: Duration = .seconds(15)
  ) {
    if deviceCount > 0 || hasClient {
      self = .allowed
    } else if let startedAt, startedAt.duration(to: .now) >= grace {
      self = .nothingFound
    } else {
      self = .probing
    }
  }

  public var label: String {
    switch self {
    case .allowed: return "Allowed"
    case .probing: return "Checking…"
    case .nothingFound: return "No soundbar found"
    }
  }

  public var symbol: String {
    switch self {
    case .allowed: return "checkmark.circle.fill"
    case .probing: return "magnifyingglass"
    case .nothingFound: return "exclamationmark.circle"
    }
  }

  public var isWarning: Bool { self == .nothingFound }
}
