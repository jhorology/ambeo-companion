import Foundation

struct AmbeoEntry<T: Decodable>: Decodable {
  let path: String?
  let title: String?
  let modifiable: Bool?
  let type: String
  let value: T?
  let edit: AmbeoEditInfo?
  let timestamp: Int64?
}

struct AmbeoEditInfo: Decodable {
  let type: String
  let min: String?
  let max: String?
  let step: String?
  let enumPath: String?
}

struct AmbeoUpdateEvent<T: Decodable> {
  let path: String
  let entry: AmbeoEntry<T>
  let newValue: T
}

struct AmbeoPowerTarget: Decodable {
  let target: String  // "online", "standby"
  let reason: String  // "userActivity"
  let nextTarget: String?
}

struct AmbeoPlayLogicData: Decodable {
  let state: String  // "playing", "paused"
  let mediaRoles: MediaRole

  struct MediaRole: Decodable {
    let title: String
    let icon: String?
  }
}

struct AmbeoUpdateStatus: Decodable {
  let firmwareUpdateStatus: Details
  struct Details: Decodable {
    let state: String  // "checkingForUpdate"
    let downloadProgress: Int
  }
}

struct AmbeoNetworkInfo: Decodable {
  let networkInfo: Details
  struct Details: Decodable {
    let state: String  // "up", "down"
    let wireless: WirelessDetails
  }
  struct WirelessDetails: Decodable {
    let ssid: String
    let signalLevel: Int
  }
}
