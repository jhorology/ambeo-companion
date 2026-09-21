import Foundation
import Logging

extension Notification.Name {
  public static let ambeoStatusDidChange = Notification.Name("ambeoStatusDidChange")
}

public actor AmbeoClient {
  private let host: String
  private let session: URLSession
  private let decoder = JSONDecoder()

  public private(set) var state = AmbeoState()
  public private(set) var isInitialSyncCompleted = false

  private var stateCache: [String: Any] = [:]
  /// Tracks the most-recently-observed value for each registered path.
  private var latestValues: [String: Any] = [:]
  private var registeredPaths: Set<String> = []

  private var updateHandlers: [String: (Data?) async throws -> Void] = [:]

  private var isObserving = false

  public init(host: String) {
    self.host = host
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 10.0
    self.session = URLSession(configuration: config)
  }

  public func markInitialSyncCompleted() {
    isInitialSyncCompleted = true
    Logger.network.debug(
      "AmbeoClient initial sync marked as complete. Remote updates will trigger OSD."
    )
  }

  public func register<E: AmbeoEndpointProtocol>(_ endpoint: E) async {
    guard !registeredPaths.contains(endpoint.path) else { return }
    registeredPaths.insert(endpoint.path)

    do {
      var components = URLComponents()
      components.scheme = "http"
      components.host = host
      components.path = "/api/getData"
      components.queryItems = [
        URLQueryItem(name: "path", value: endpoint.path),
        URLQueryItem(name: "roles", value: "@all"),
        URLQueryItem(name: "_nocache", value: String(Int64(Date().timeIntervalSince1970 * 1000))),
      ]

      guard let url = components.url else { return }
      let (data, _) = try await session.data(from: url)

      // Hardware returns single descriptor dictionary for roles=@all, but try both single & array
      let entry: AmbeoEntry<E>?
      if let single = try? decoder.decode(AmbeoEntry<E>.self, from: data) {
        entry = single
      } else if let arr = try? decoder.decode([AmbeoEntry<E>].self, from: data),
        let first = arr.first
      {
        entry = first
      } else {
        entry = nil
      }

      if let entry {
        stateCache[endpoint.path] = entry
        if let v = entry.value {
          latestValues[endpoint.path] = v
          updateState(path: endpoint.path, newValue: v)
        }
        Logger.network.debug(
          "Registered endpoint [\(endpoint.path)]: value=\(String(describing: entry.value))"
        )
      } else {
        let text = String(data: data, encoding: .utf8) ?? ""
        Logger.network.warning("Could not decode AmbeoEntry for [\(endpoint.path)]: \(text)")
      }
    } catch {
      Logger.network.error(
        "Initial fetch failed for \(endpoint.path): \(error.localizedDescription)"
      )
    }

    updateHandlers[endpoint.path] = { [weak self] itemValueData in
      guard let self = self else { return }
      if let itemValueData {
        if let container = try? self.decoder.decode(
          AmbeoValueContainer<E.Payload>.self,
          from: itemValueData
        ) {
          await self.notifyUpdate(path: endpoint.path, newValue: container.decodedValue)
          return
        }
      }
      // Fallback: re-fetch if itemValue is absent or decode failed
      if let refetched = await self.fetchDirectValue(for: endpoint) {
        await self.notifyUpdate(path: endpoint.path, newValue: refetched)
      }
    }
  }

  private func fetchDirectValue<E: AmbeoEndpointProtocol>(for endpoint: E) async -> E.Payload? {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.path = "/api/getData"
    components.queryItems = [
      URLQueryItem(name: "path", value: endpoint.path),
      URLQueryItem(name: "roles", value: "@all"),
      URLQueryItem(name: "_nocache", value: String(Int64(Date().timeIntervalSince1970 * 1000))),
    ]
    guard let url = components.url,
      let (data, _) = try? await session.data(from: url)
    else { return nil }
    if let single = try? decoder.decode(AmbeoEntry<E>.self, from: data) {
      stateCache[endpoint.path] = single
      return single.value
    }
    return nil
  }

  private func updateState<V>(path: String, newValue: V) {
    latestValues[path] = newValue

    if path == "player:volume", let v = newValue as? Int {
      state.volume = v
    } else if path == "settings:/mediaPlayer/mute", let m = newValue as? Bool {
      state.isMuted = m
    } else if path == "settings:/popcorn/audio/audioPresets/audioPreset",
      let p = newValue as? String
    {
      state.preset = p
      if let level = state.ambeoLevels[p.lowercased()] {
        state.ambeoLevel = level
      }
    } else if path == "settings:/popcorn/audio/ambeoModeStatus", let m = newValue as? Bool {
      state.isAmbeoMode = m
    } else if path.hasPrefix("settings:/popcorn/audio/audioPresets/ambeoModeLevel_"),
      let l = newValue as? String
    {
      let presetName = path.replacingOccurrences(
        of: "settings:/popcorn/audio/audioPresets/ambeoModeLevel_",
        with: ""
      ).lowercased()
      state.ambeoLevels[presetName] = l
      if state.preset.lowercased() == presetName {
        state.ambeoLevel = l
      }
    } else if path == "settings:/popcorn/audio/nightModeStatus", let n = newValue as? Bool {
      state.isNightMode = n
    } else if path == "settings:/popcorn/audio/voiceEnhancement", let ve = newValue as? Bool {
      state.isVoiceEnhancement = ve
    } else if path == "uipopcorn:ecoModeState", let eco = newValue as? Bool {
      state.isEcoMode = eco
    } else if path == "settings:/system/maxIdleTime", let idle = newValue as? Int {
      state.maxIdleTime = idle
    } else if path == "imx8af:decoderAudioFormat", let af = newValue as? AmbeoAudioFormat {
      state.audioFormat = af
    } else if path == "powermanager:target" {
      if let pt = newValue as? AmbeoPowerTarget {
        state.powerTarget = pt.target
      } else if let s = newValue as? String {
        state.powerTarget = s
      }
    }
  }

  private func notifyUpdate<V>(path: String, newValue: V) {
    updateState(path: path, newValue: newValue)

    let notifPath = path
    let isExternal = isInitialSyncCompleted
    DispatchQueue.main.async {
      NotificationCenter.default.post(
        name: .ambeoStatusDidChange,
        object: nil,
        userInfo: [
          "path": notifPath,
          "isExternal": isExternal,
        ]
      )
    }
  }

  // MARK: - Polling Loop

  public func startObserving() async {
    guard !isObserving, !registeredPaths.isEmpty else { return }
    isObserving = true

    Task {
      Logger.network.info(
        "AMBEO event observation loop started for \(self.registeredPaths.count) paths."
      )
      while isObserving {
        guard let qId = await setupAmbeoSubscription() else {
          Logger.network.warning("Subscription failed. Retrying in 5s...")
          try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
          continue
        }

        while isObserving {
          var components = URLComponents()
          components.scheme = "http"
          components.host = host
          components.path = "/api/event/pollQueue"
          components.queryItems = [
            URLQueryItem(name: "queueId", value: qId),
            URLQueryItem(name: "timeout", value: "2000"),
            URLQueryItem(
              name: "_nocache",
              value: String(Int64(Date().timeIntervalSince1970 * 1000))
            ),
          ]

          guard let pollUrl = components.url else { break }

          var request = URLRequest(url: pollUrl)
          request.timeoutInterval = 30.0

          do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (400...599).contains(http.statusCode) {
              Logger.network.warning(
                "pollQueue failed with HTTP \(http.statusCode). Re-establishing queue..."
              )
              break
            }
            try await processPollResponse(data)
          } catch let error as URLError where error.code == .timedOut {
            // Long-poll timed out normally on server side; continue polling on existing queue
            continue
          } catch {
            Logger.network.notice(
              "Polling connection interrupted: \(error.localizedDescription). Reconnecting in 3s..."
            )
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            break
          }
        }
      }
    }
  }

  // MARK: - Queue Setup

  private func setupAmbeoSubscription() async -> String? {
    do {
      let nocache = String(Int64(Date().timeIntervalSince1970 * 1000))

      var initComponents = URLComponents()
      initComponents.scheme = "http"
      initComponents.host = host
      initComponents.path = "/api/event/modifyQueue"
      initComponents.queryItems = [
        URLQueryItem(name: "queueId", value: ""),
        URLQueryItem(name: "subscribe", value: "[]"),
        URLQueryItem(name: "unsubscribe", value: "[]"),
        URLQueryItem(name: "_nocache", value: nocache),
      ]

      guard let initUrl = initComponents.url else { return nil }
      let (initData, _) = try await session.data(from: initUrl)

      let trimChars = CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines)
      guard let rawQId = String(data: initData, encoding: .utf8)?.trimmingCharacters(in: trimChars),
        !rawQId.isEmpty
      else { return nil }

      let pathsToSubscribe = Array(registeredPaths)
      let subscribeArray = pathsToSubscribe.map { ["path": $0, "type": "itemWithValue"] }
      let subscribeData = try JSONSerialization.data(withJSONObject: subscribeArray)
      let subscribeString = String(data: subscribeData, encoding: .utf8)!

      var regComponents = URLComponents()
      regComponents.scheme = "http"
      regComponents.host = host
      regComponents.path = "/api/event/modifyQueue"
      regComponents.queryItems = [
        URLQueryItem(name: "queueId", value: rawQId),
        URLQueryItem(name: "subscribe", value: subscribeString),
        URLQueryItem(name: "unsubscribe", value: "[]"),
        URLQueryItem(name: "_nocache", value: String(Int64(Date().timeIntervalSince1970 * 1000))),
      ]

      guard let regUrl = regComponents.url else { return nil }
      _ = try await session.data(from: regUrl)

      Logger.network.info("Subscribed queue [\(rawQId)] to \(pathsToSubscribe.count) paths.")
      return rawQId

    } catch {
      Logger.network.error("setupAmbeoSubscription error: \(error.localizedDescription)")
      return nil
    }
  }

  private func processPollResponse(_ data: Data) async throws {
    if data.isEmpty || data == Data("[]".utf8) { return }
    guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
      !jsonArray.isEmpty
    else { return }

    for json in jsonArray {
      guard let path = json["path"] as? String,
        json["itemType"] == nil || json["itemType"] as? String == "update"
          || json["rowsType"] as? String == "update",
        let handler = updateHandlers[path]
      else { continue }

      let itemValueDict = json["itemValue"] as? [String: Any]
      let itemValueData = itemValueDict.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
      try? await handler(itemValueData)
    }
  }

  public func getValue<E: AmbeoEndpointProtocol>(for endpoint: E) -> E.Payload? {
    if let latest = latestValues[endpoint.path] as? E.Payload { return latest }
    return (stateCache[endpoint.path] as? AmbeoEntry<E>)?.value
  }

  public func getEntry<E: AmbeoEndpointProtocol>(for endpoint: E) -> AmbeoEntry<E>? {
    stateCache[endpoint.path] as? AmbeoEntry<E>
  }

  /// Sets a value on a device path. Automatically includes required `role=value` parameter and cache buster.
  public func set<E: AmbeoEndpointProtocol>(
    _ endpoint: E,
    valueJSON: String,
    role: String = "value"
  ) async throws {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.path = "/api/setData"
    components.queryItems = [
      URLQueryItem(name: "path", value: endpoint.path),
      URLQueryItem(name: "role", value: role),
      URLQueryItem(name: "value", value: valueJSON),
      URLQueryItem(name: "_nocache", value: String(Int64(Date().timeIntervalSince1970 * 1000))),
    ]

    guard let url = components.url else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"

    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      let body = String(data: data, encoding: .utf8) ?? ""
      Logger.network.error("setData error: HTTP \(http.statusCode): \(body)")
    } else {
      if let single = try? decoder.decode(AmbeoEntry<E>.self, from: data), let v = single.value {
        updateState(path: endpoint.path, newValue: v)
      }
    }
  }
}
