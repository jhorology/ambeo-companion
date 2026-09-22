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

  /// Heterogeneous endpoint entries, keyed by path. Each path is registered once
  /// with a single payload type; mismatched reads are logged in `getValue` / `getEntry`.
  private var stateCache: [String: Any] = [:]
  /// Tracks the most-recently-observed value for each registered path.
  private var latestValues: [String: Any] = [:]
  private var registeredPaths: Set<String> = []
  private var stateUpdaters: [String: @Sendable (Any, inout AmbeoState) -> Void] = [:]
  /// Tracks values set locally by this client to suppress echo notifications from the pollQueue.
  private var expectedEchoValues: [String: Set<String>] = [:]

  private var updateHandlers: [String: (Data?) async throws -> Void] = [:]

  private var isObserving = false
  private var pollTask: Task<Void, Never>?

  public func stopObserving() {
    isObserving = false
    pollTask?.cancel()
    pollTask = nil
  }

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
    stateUpdaters[endpoint.path] = { value, state in
      if let v = value as? E.Payload {
        endpoint.apply(v, to: &state)
      }
    }

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
      await self?.applyPollUpdate(itemValueData, for: endpoint)
    }
  }

  private func applyPollUpdate<E: AmbeoEndpointProtocol>(
    _ itemValueData: Data?,
    for endpoint: E
  ) async {
    if let itemValueData {
      do {
        let container = try decoder.decode(
          AmbeoValueContainer<E.Payload>.self,
          from: itemValueData
        )
        notifyUpdate(path: endpoint.path, newValue: container.decodedValue)
        return
      } catch {
        Logger.network.warning(
          "Poll value decode failed for [\(endpoint.path)]: \(error.localizedDescription). Refetching."
        )
      }
    }
    // Fallback: re-fetch if itemValue is absent or decode failed
    if let refetched = await fetchDirectValue(for: endpoint) {
      notifyUpdate(path: endpoint.path, newValue: refetched)
    } else if itemValueData != nil {
      Logger.network.warning(
        "Poll update for [\(endpoint.path)] could not be decoded or refetched."
      )
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
    if let updater = stateUpdaters[path] {
      updater(newValue, &state)
    }
  }

  /// Distinguishes values whose descriptions collide across types, such as `Int(1)` and `"1"`.
  private func echoToken<V>(_ value: V) -> String {
    "\(type(of: value)):\(value)"
  }

  private func notifyUpdate<V>(path: String, newValue: V) {
    updateState(path: path, newValue: newValue)

    let notifPath = path
    let valStr = echoToken(newValue)
    let isEcho = expectedEchoValues[path]?.contains(valStr) == true
    if isEcho {
      expectedEchoValues[path]?.remove(valStr)
      if expectedEchoValues[path]?.isEmpty == true {
        expectedEchoValues.removeValue(forKey: path)
      }
    }
    let isExternal = isInitialSyncCompleted && !isEcho
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

    pollTask?.cancel()
    pollTask = Task {
      Logger.network.info(
        "AMBEO event observation loop started for \(self.registeredPaths.count) paths."
      )
      var retryDelaySeconds: UInt64 = 3
      while isObserving {
        guard let qId = await setupAmbeoSubscription() else {
          Logger.network.warning("Subscription failed. Retrying in \(retryDelaySeconds)s...")
          try? await Task.sleep(nanoseconds: retryDelaySeconds * 1_000_000_000)
          retryDelaySeconds = min(retryDelaySeconds * 2, 60)
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
                "pollQueue failed with HTTP \(http.statusCode). Re-establishing queue in \(retryDelaySeconds)s..."
              )
              try? await Task.sleep(nanoseconds: retryDelaySeconds * 1_000_000_000)
              retryDelaySeconds = min(retryDelaySeconds * 2, 60)
              break
            }
            try await processPollResponse(data)
            retryDelaySeconds = 3
          } catch let error as URLError where error.code == .timedOut {
            // Long-poll timed out normally on server side; continue polling on existing queue
            continue
          } catch {
            Logger.network.notice(
              "Polling connection interrupted: \(error.localizedDescription). Reconnecting in \(retryDelaySeconds)s..."
            )
            try? await Task.sleep(nanoseconds: retryDelaySeconds * 1_000_000_000)
            retryDelaySeconds = min(retryDelaySeconds * 2, 60)
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
      let subscribeString = String(data: subscribeData, encoding: .utf8) ?? ""

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

      let itemValueData: Data?
      if let itemValueDict = json["itemValue"] as? [String: Any] {
        do {
          itemValueData = try JSONSerialization.data(withJSONObject: itemValueDict)
        } catch {
          Logger.network.warning(
            "Failed to serialize itemValue for [\(path)]: \(error.localizedDescription)"
          )
          itemValueData = nil
        }
      } else {
        itemValueData = nil
      }
      do {
        try await handler(itemValueData)
      } catch {
        Logger.network.warning(
          "Poll handler failed for [\(path)]: \(error.localizedDescription)"
        )
      }
    }
  }

  public func getValue<E: AmbeoEndpointProtocol>(for endpoint: E) -> E.Payload? {
    if let stored = latestValues[endpoint.path] {
      guard let latest = stored as? E.Payload else {
        Logger.network.error(
          "Cached value type mismatch for [\(endpoint.path)]: stored \(type(of: stored)), expected \(E.Payload.self)"
        )
        return nil
      }
      return latest
    }
    return getEntry(for: endpoint)?.value
  }

  public func getEntry<E: AmbeoEndpointProtocol>(for endpoint: E) -> AmbeoEntry<E>? {
    guard let cached = stateCache[endpoint.path] else { return nil }
    guard let entry = cached as? AmbeoEntry<E> else {
      Logger.network.error(
        "Cached entry type mismatch for [\(endpoint.path)]: stored \(type(of: cached))"
      )
      return nil
    }
    return entry
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
    // AMBEO `/api/setData` takes the new value in the query string and expects GET.
    request.httpMethod = "GET"

    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      let body = String(data: data, encoding: .utf8) ?? ""
      Logger.network.error("setData error: HTTP \(http.statusCode): \(body)")
      throw URLError(.badServerResponse)
    } else {
      var updatedValue: E.Payload? = nil
      if let single = try? decoder.decode(AmbeoEntry<E>.self, from: data), let v = single.value {
        updatedValue = v
      } else if let container = try? decoder.decode(
        AmbeoValueContainer<E.Payload>.self,
        from: Data(valueJSON.utf8)
      ) {
        updatedValue = container.decodedValue
      }

      if let v = updatedValue {
        updateState(path: endpoint.path, newValue: v)
        expectedEchoValues[endpoint.path, default: []].insert(echoToken(v))
      }
    }
  }
}
