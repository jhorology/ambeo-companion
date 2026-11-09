import Foundation

/// Where the volume OSD appears on the screen under the mouse pointer.
enum OverlayPosition: String, Codable, CaseIterable, Sendable {
  /// Screen center (the classic pre-Tahoe OSD spot).
  case center
  /// Below the menu bar, centered (where macOS shows brightness).
  case topCenter
  /// Below the menu bar, right-aligned (where macOS shows volume).
  case topRight

  var displayName: String {
    switch self {
    case .center: return "Center"
    case .topCenter: return "Top Center"
    case .topRight: return "Top Right"
    }
  }
}

struct AppSettings: Codable, Equatable, Sendable {
  var ambeoUid: String = ""
  var audioDeviceUid: String = ""
  /// Stored as the format's `displayName` (which equals its `id`)
  var fallbackAudioFormatID: String = ""
  var mediaKeyEnabled: Bool = true
  var stealthRewindEnabled: Bool = false
  var stealthRewindDelayMs: Int = 250
  var atmosBoostAmount: Double = 0
  var autoStandbySeconds: Int = 0
  var overlayPosition: OverlayPosition = .center

  enum CodingKeys: String, CodingKey {
    case ambeoUid, audioDeviceUid, fallbackAudioFormatID, mediaKeyEnabled, stealthRewindEnabled,
      stealthRewindDelayMs, atmosBoostAmount, autoStandbySeconds, overlayPosition
  }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ambeoUid = try container.decodeIfPresent(String.self, forKey: .ambeoUid) ?? ""
    audioDeviceUid = try container.decodeIfPresent(String.self, forKey: .audioDeviceUid) ?? ""
    fallbackAudioFormatID =
      try container.decodeIfPresent(String.self, forKey: .fallbackAudioFormatID) ?? ""
    mediaKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .mediaKeyEnabled) ?? true
    stealthRewindEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .stealthRewindEnabled) ?? false
    stealthRewindDelayMs =
      try container.decodeIfPresent(Int.self, forKey: .stealthRewindDelayMs) ?? 250
    atmosBoostAmount = try container.decodeIfPresent(Double.self, forKey: .atmosBoostAmount) ?? 0
    autoStandbySeconds = try container.decodeIfPresent(Int.self, forKey: .autoStandbySeconds) ?? 0
    // `try?` so an unknown value from a newer build falls back instead of resetting everything.
    overlayPosition =
      (try? container.decodeIfPresent(OverlayPosition.self, forKey: .overlayPosition)) ?? .center
  }
}
