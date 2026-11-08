import Foundation

@propertyWrapper public struct Stringified<T: LosslessStringConvertible>: Decodable, Sendable
where T: Sendable {
  public var wrappedValue: T?

  public init(wrappedValue: T? = nil) { self.wrappedValue = wrappedValue }

  /// AMBEO firmware has been observed to send `edit.min/max/step` as JSON strings (`"1"`), and it
  /// can answer the same fields as bare numbers (`1`, `1.5`). Accept strings, integers, doubles,
  /// and booleans so a numeric reply does not silently drop to the caller's fallback defaults
  /// (volume step 1, range 0...100).
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self.wrappedValue = nil
      return
    }
    if let stringValue = try? container.decode(String.self) {
      self.wrappedValue = T(stringValue)
      return
    }
    if let intValue = try? container.decode(Int.self) {
      self.wrappedValue = T(String(intValue))
      return
    }
    if let doubleValue = try? container.decode(Double.self) {
      // `T` may be Int, which cannot parse "25.0"; normalise integral doubles first.
      if doubleValue == doubleValue.rounded(), abs(doubleValue) < 1e15 {
        self.wrappedValue = T(String(Int64(doubleValue))) ?? T(String(doubleValue))
      } else {
        self.wrappedValue = T(String(doubleValue))
      }
      return
    }
    if let boolValue = try? container.decode(Bool.self) {
      self.wrappedValue = T(boolValue ? "true" : "false")
      return
    }
    // Unrecognised JSON (object, array): keep the existing lenient behaviour of decoding to nil.
    self.wrappedValue = nil
  }
}

public struct AmbeoValueContainer<T: Decodable>: Decodable {
  public let decodedValue: T

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicKey.self)

    let typeKey = try container.decode(String.self, forKey: DynamicKey(stringValue: "type")!)

    guard !typeKey.isEmpty else {
      throw DecodingError.dataCorruptedError(
        forKey: DynamicKey(stringValue: "type")!,
        in: container,
        debugDescription: "Empty value type"
      )
    }
    self.decodedValue = try container.decode(T.self, forKey: DynamicKey(stringValue: typeKey)!)
  }
}

public struct DynamicKey: CodingKey {
  public var stringValue: String
  public var intValue: Int? { nil }
  public init?(stringValue: String) { self.stringValue = stringValue }
  public init?(intValue: Int) { nil }
}

public struct AmbeoEntry<E: AmbeoEndpointProtocol>: Decodable, Sendable {
  public let title: String?
  public let modifiable: Bool?
  public let edit: E.Edit?
  public let value: E.Payload?

  enum CodingKeys: String, CodingKey { case title, modifiable, edit, value }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.title = try container.decodeIfPresent(String.self, forKey: .title)
    self.modifiable = try container.decodeIfPresent(Bool.self, forKey: .modifiable)
    self.edit = try container.decodeIfPresent(E.Edit.self, forKey: .edit)

    if let valContainer = try container.decodeIfPresent(
      AmbeoValueContainer<E.Payload>.self,
      forKey: .value
    ) {
      self.value = valContainer.decodedValue
    } else {
      self.value = nil
    }
  }
}

public struct AmbeoUpdateEvent<E: AmbeoEndpointProtocol> {
  public let path: String
  public let entry: AmbeoEntry<E>
  public let newValue: E.Payload
}

public struct AmbeoPowerTarget: Decodable, Sendable {
  public let target: String
  public let reason: String?
  public let nextTarget: String?
  public let nextReason: String?
}

public struct AmbeoPlayLogicData: Decodable, Sendable { public let state: String }

public struct AmbeoAudioFormat: Decodable, Sendable, Equatable {
  public let codec: String?
  public let channels: Int?
  public let sampleRate: Double?

  public init(codec: String? = nil, channels: Int? = nil, sampleRate: Double? = nil) {
    self.codec = codec
    self.channels = channels
    self.sampleRate = sampleRate
  }

  public var isAtmos: Bool {
    guard let codec, !codec.isEmpty else { return false }
    return codec.localizedCaseInsensitiveContains("atmos")
  }
}

public struct AmbeoState: Equatable, Sendable {
  public var volume: Int = 0
  public var isMuted: Bool = false
  public var preset: String = "adaptive"
  public var isAmbeoMode: Bool = true
  public var ambeoLevel: String = "standard"
  public var ambeoLevels: [String: String] = [:]
  public var isNightMode: Bool = false
  public var isVoiceEnhancement: Bool = false
  public var isEcoMode: Bool = false
  public var maxIdleTime: Int = 900
  public var powerTarget: String = "online"
  public var audioFormat: AmbeoAudioFormat? = nil

  public init(
    volume: Int = 0,
    isMuted: Bool = false,
    preset: String = "adaptive",
    isAmbeoMode: Bool = true,
    ambeoLevel: String = "standard",
    ambeoLevels: [String: String] = [:],
    isNightMode: Bool = false,
    isVoiceEnhancement: Bool = false,
    isEcoMode: Bool = false,
    maxIdleTime: Int = 900,
    powerTarget: String = "online",
    audioFormat: AmbeoAudioFormat? = nil
  ) {
    self.volume = volume
    self.isMuted = isMuted
    self.preset = preset
    self.isAmbeoMode = isAmbeoMode
    self.ambeoLevel = ambeoLevel
    self.ambeoLevels = ambeoLevels
    self.isNightMode = isNightMode
    self.isVoiceEnhancement = isVoiceEnhancement
    self.isEcoMode = isEcoMode
    self.maxIdleTime = maxIdleTime
    self.powerTarget = powerTarget
    self.audioFormat = audioFormat
  }
}
