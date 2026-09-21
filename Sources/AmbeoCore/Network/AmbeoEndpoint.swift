import Foundation

public protocol AmbeoEndpointProtocol: Sendable {
  associatedtype Payload: Decodable & Sendable
  associatedtype Edit: Decodable & Sendable
  var path: String { get }
}

public struct NoEdit: Decodable, Sendable {
  public init() {}
}

public enum AmbeoEndpoint {
  public enum Player {
    public struct Volume: AmbeoEndpointProtocol {
      public typealias Payload = Int
      public let path = "player:volume"

      public struct Edit: Decodable, Sendable {
        @Stringified public var min: Int?
        @Stringified public var max: Int?
        @Stringified public var step: Int?
      }

      public init() {}
    }

    public struct Mute: AmbeoEndpointProtocol {
      public typealias Payload = Bool
      public typealias Edit = NoEdit
      public let path = "settings:/mediaPlayer/mute"
      public init() {}
    }

    public struct PlayTime: AmbeoEndpointProtocol {
      public typealias Payload = Int64
      public typealias Edit = NoEdit
      public let path = "player:player/data/playTime"
      public init() {}
    }
  }

  public enum Audio {
    public struct Preset: AmbeoEndpointProtocol {
      public typealias Payload = String
      public let path = "settings:/popcorn/audio/audioPresets/audioPreset"
      public static let allPresets: [String] = [
        "adaptive", "music", "movie", "news", "neutral", "sports",
      ]

      public struct Edit: Decodable, Sendable {
        public let enumPath: String?
      }

      public init() {}
    }

    public struct AmbeoMode: AmbeoEndpointProtocol {
      public typealias Payload = Bool
      public typealias Edit = NoEdit
      public let path = "settings:/popcorn/audio/ambeoModeStatus"
      public init() {}
    }

    public struct AmbeoLevel: AmbeoEndpointProtocol {
      public typealias Payload = String
      public typealias Edit = NoEdit
      public let path: String
      public static let allLevels: [String] = ["light", "standard", "boost"]

      public init(preset: String = "adaptive") {
        self.path = "settings:/popcorn/audio/audioPresets/ambeoModeLevel_\(preset)"
      }
    }

    public struct NightMode: AmbeoEndpointProtocol {
      public typealias Payload = Bool
      public typealias Edit = NoEdit
      public let path = "settings:/popcorn/audio/nightModeStatus"
      public init() {}
    }

    public struct VoiceEnhancement: AmbeoEndpointProtocol {
      public typealias Payload = Bool
      public typealias Edit = NoEdit
      public let path = "settings:/popcorn/audio/voiceEnhancement"
      public init() {}
    }

    public struct EcoMode: AmbeoEndpointProtocol {
      public typealias Payload = Bool
      public typealias Edit = NoEdit
      public let path = "uipopcorn:ecoModeState"
      public init() {}
    }

    public struct DecoderAudioFormat: AmbeoEndpointProtocol {
      public typealias Payload = AmbeoAudioFormat
      public typealias Edit = NoEdit
      public let path = "imx8af:decoderAudioFormat"
      public init() {}
    }
  }

  public enum System {
    public struct Power: AmbeoEndpointProtocol {
      public typealias Payload = AmbeoPowerTarget
      public typealias Edit = NoEdit
      public let path = "powermanager:target"
      public init() {}
    }

    public struct MaxIdleTime: AmbeoEndpointProtocol {
      public typealias Payload = Int
      public typealias Edit = NoEdit
      public let path = "settings:/system/maxIdleTime"
      public init() {}
    }
  }
}
