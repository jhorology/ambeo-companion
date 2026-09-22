import Foundation

public protocol AmbeoEndpointProtocol: Sendable {
  associatedtype Payload: Decodable & Sendable
  associatedtype Edit: Decodable & Sendable
  var path: String { get }
  func apply(_ value: Payload, to state: inout AmbeoState)
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
      public func apply(_ value: Payload, to state: inout AmbeoState) { state.volume = value }
    }

    public struct Mute: AmbeoEndpointProtocol {
      public typealias Payload = Bool
      public typealias Edit = NoEdit
      public let path = "settings:/mediaPlayer/mute"
      public init() {}
      public func apply(_ value: Payload, to state: inout AmbeoState) { state.isMuted = value }
    }

    public struct PlayTime: AmbeoEndpointProtocol {
      public typealias Payload = Int64
      public typealias Edit = NoEdit
      public let path = "player:player/data/playTime"
      public init() {}
      public func apply(_ value: Payload, to state: inout AmbeoState) {}
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
      public func apply(_ value: Payload, to state: inout AmbeoState) {
        state.preset = value
        if let level = state.ambeoLevels[value.lowercased()] {
          state.ambeoLevel = level
        }
      }
    }

    public struct AmbeoMode: AmbeoEndpointProtocol {
      public typealias Payload = Bool
      public typealias Edit = NoEdit
      public let path = "settings:/popcorn/audio/ambeoModeStatus"
      public init() {}
      public func apply(_ value: Payload, to state: inout AmbeoState) { state.isAmbeoMode = value }
    }

    public struct AmbeoLevel: AmbeoEndpointProtocol {
      public typealias Payload = String
      public typealias Edit = NoEdit
      public let path: String
      public let preset: String
      public static let allLevels: [String] = ["light", "standard", "boost"]

      public init(preset: String = "adaptive") {
        self.preset = preset
        self.path = "settings:/popcorn/audio/audioPresets/ambeoModeLevel_\(preset)"
      }
      public func apply(_ value: Payload, to state: inout AmbeoState) {
        let presetName = self.preset.lowercased()
        state.ambeoLevels[presetName] = value
        if state.preset.lowercased() == presetName {
          state.ambeoLevel = value
        }
      }
    }

    public struct NightMode: AmbeoEndpointProtocol {
      public typealias Payload = Bool
      public typealias Edit = NoEdit
      public let path = "settings:/popcorn/audio/nightModeStatus"
      public init() {}
      public func apply(_ value: Payload, to state: inout AmbeoState) { state.isNightMode = value }
    }

    public struct VoiceEnhancement: AmbeoEndpointProtocol {
      public typealias Payload = Bool
      public typealias Edit = NoEdit
      public let path = "settings:/popcorn/audio/voiceEnhancement"
      public init() {}
      public func apply(_ value: Payload, to state: inout AmbeoState) { state.isVoiceEnhancement = value }
    }

    public struct EcoMode: AmbeoEndpointProtocol {
      public typealias Payload = Bool
      public typealias Edit = NoEdit
      public let path = "uipopcorn:ecoModeState"
      public init() {}
      public func apply(_ value: Payload, to state: inout AmbeoState) { state.isEcoMode = value }
    }

    public struct DecoderAudioFormat: AmbeoEndpointProtocol {
      public typealias Payload = AmbeoAudioFormat
      public typealias Edit = NoEdit
      public let path = "imx8af:decoderAudioFormat"
      public init() {}
      public func apply(_ value: Payload, to state: inout AmbeoState) { state.audioFormat = value }
    }
  }

  public enum System {
    public struct Power: AmbeoEndpointProtocol {
      public typealias Payload = AmbeoPowerTarget
      public typealias Edit = NoEdit
      public let path = "powermanager:target"
      public init() {}
      public func apply(_ value: Payload, to state: inout AmbeoState) { state.powerTarget = value.target }
    }

    public struct MaxIdleTime: AmbeoEndpointProtocol {
      public typealias Payload = Int
      public typealias Edit = NoEdit
      public let path = "settings:/system/maxIdleTime"
      public init() {}
      public func apply(_ value: Payload, to state: inout AmbeoState) { state.maxIdleTime = value }
    }
  }
}
