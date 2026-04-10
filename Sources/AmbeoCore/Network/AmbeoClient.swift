import Foundation
import Logging

extension Notification.Name {
  static let ambeoStatusDidChange = Notification.Name("ambeoStatusDidChange")
}

actor AmbeoClient {
  private let host: String
  private let session: URLSession
  private let decoder = JSONDecoder()

  private var stateCache: [String: Any] = [:]
  private var registeredPaths: Set<String> = []

  private var updateHandlers: [String: (Data) async throws -> Void] = [:]

  private var isObserving = false

  init(host: String) {
    self.host = host
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 10.0
    self.session = URLSession(configuration: config)
  }

  func register<E: AmbeoEndpointProtocol>(_ endpoint: E) async {
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
      ]

      guard let url = components.url else { return }
      let (data, _) = try await session.data(from: url)

      let entries = try decoder.decode([AmbeoEntry<E>].self, from: data)
      if let first = entries.first {
        stateCache[endpoint.path] = first
      }
    } catch {
      Logger.network.error(
        "⚠️ Initial fetch failed for \(endpoint.path): \(error.localizedDescription)"
      )
    }

    updateHandlers[endpoint.path] = { [weak self] itemValueData in
      guard let self = self else { return }
      let container = try self.decoder.decode(
        AmbeoValueContainer<E.Payload>.self,
        from: itemValueData
      )
      let newValue = container.decodedValue
      await self.notifyUpdate(path: endpoint.path, newValue: newValue, endpointType: E.self)
    }
  }

  private func notifyUpdate<E: AmbeoEndpointProtocol>(
    path: String,
    newValue: E.Payload,
    endpointType: E.Type
  ) {
    guard let cachedEntry = stateCache[path] as? AmbeoEntry<E> else { return }

    let event = AmbeoUpdateEvent(path: path, entry: cachedEntry, newValue: newValue)
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .ambeoStatusDidChange, object: event)
    }
  }

  func startObserving() async {
    guard !isObserving, !registeredPaths.isEmpty else { return }
    isObserving = true

    Task {
      while isObserving {
        guard let qId = await setupAmbeoSubscription() else {
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
            URLQueryItem(name: "timeout", value: "1500"),
            URLQueryItem(name: "_nocache", value: String(Int(Date().timeIntervalSince1970 * 1000))),
          ]

          guard let pollUrl = components.url else { break }

          do {
            let (data, _) = try await session.data(from: pollUrl)
            try await processPollResponse(data)
          } catch {
            break
          }
        }
      }
    }
  }

  private func setupAmbeoSubscription() async -> String? {
    do {
      let nocache = String(Int(Date().timeIntervalSince1970 * 1000))

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

      var pathsToSubscribe = Array(registeredPaths)
      let mandatoryPath = "player:player/data/playTime"
      if !pathsToSubscribe.contains(mandatoryPath) {
        pathsToSubscribe.append(mandatoryPath)
        print("🔧 AMBEOハック: タイムアウト維持のため \(mandatoryPath) を強制購読します")
      }

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
      ]

      guard let regUrl = regComponents.url else { return nil }
      _ = try await session.data(from: regUrl)

      return rawQId

    } catch {
      return nil
    }
  }

  private func processPollResponse(_ data: Data) async throws {
    guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
      !jsonArray.isEmpty
    else { return }

    for json in jsonArray {
      guard let path = json["path"] as? String,
        json["itemType"] as? String == "update",
        let itemValueDict = json["itemValue"] as? [String: Any],
        let handler = updateHandlers[path]
      else { continue }

      if let itemValueData = try? JSONSerialization.data(withJSONObject: itemValueDict) {
        try? await handler(itemValueData)
      }
    }
  }

  func getValue<E: AmbeoEndpointProtocol>(for endpoint: E) -> E.Payload? {
    let entry = stateCache[endpoint.path] as? AmbeoEntry<E>
    return entry?.value
  }

  func getEntry<E: AmbeoEndpointProtocol>(for endpoint: E) -> AmbeoEntry<E>? {
    stateCache[endpoint.path] as? AmbeoEntry<E>
  }

  func set<E: AmbeoEndpointProtocol>(_ endpoint: E, valueJSON: String) async throws {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.path = "/api/setData"
    components.queryItems = [
      URLQueryItem(name: "path", value: endpoint.path),
      URLQueryItem(name: "value", value: valueJSON),
    ]

    guard let url = components.url else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"

    _ = try await session.data(for: request)
  }
}
