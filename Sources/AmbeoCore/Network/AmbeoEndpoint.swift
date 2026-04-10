import Foundation

protocol AmbeoEndpointProtocol {
  associatedtype Response: Decodable
  var path: String { get }
}

enum AmbeoEndpoint {
  enum Player {
    struct Volume: AmbeoEndpointProtocol {
      typealias Response = Int
      let path = "player:volume"
    }
    struct Mute: AmbeoEndpointProtocol {
      typealias Response = Bool
      let path = "settings:/mediaPlayer/mute"
    }
    struct PlayData: AmbeoEndpointProtocol {
      typealias Response = AmbeoPlayLogicData
      let path = "player:player/data/value"
    }
    struct PlayTime: AmbeoEndpointProtocol {
      typealias Response = Int64
      let path = "player:player/data/playTime"
    }
  }

  enum Audio {
    struct Preset: AmbeoEndpointProtocol {
      typealias Response = String
      let path = "settings:/popcorn/audio/audioPresets/audioPreset"
    }
    struct AmbeoMode: AmbeoEndpointProtocol {
      typealias Response = Bool
      let path = "settings:/popcorn/audio/ambeoModeStatus"
    }
  }

  enum System {
    struct Power: AmbeoEndpointProtocol {
      typealias Response = AmbeoPowerTarget
      let path = "powermanager:target"
    }
    struct ProductName: AmbeoEndpointProtocol {
      typealias Response = String
      let path = "settings:/system/productName"
    }
  }
}
