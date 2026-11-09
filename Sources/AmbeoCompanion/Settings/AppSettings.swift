import Foundation

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

  enum CodingKeys: String, CodingKey {
    case ambeoUid, audioDeviceUid, fallbackAudioFormatID, mediaKeyEnabled, stealthRewindEnabled,
      stealthRewindDelayMs, atmosBoostAmount, autoStandbySeconds
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
  }
}
