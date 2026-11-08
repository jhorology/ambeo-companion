import Foundation
import Logging
import Network

public struct SennheiserNetworkDevice: Sendable, Identifiable, Hashable, Codable {
  public var id: String { uuid }
  public let uuid: String  // device uuid
  public let serial: String  // device serial number
  public let name: String  // user friendly name (Google/Apple Home device name)
  public let ip: String  // ipv4 address

  /// Why a TXT record was rejected, so discovery can log the reason and tests can assert on it.
  public enum ParseFailure: Error, Equatable, Sendable {
    case missingField(String)
    case malformedUUID(String)
    case malformedIPv4Address(String)
  }

  public init(uuid: String, serial: String, name: String, ip: String) {
    self.uuid = uuid
    self.serial = serial
    self.name = name
    self.ip = ip
  }

  init?(withDict dict: [String: String]) {
    guard case let .success(device) = Self.parse(dict) else { return nil }
    self = device
  }

  /// The uuid is what the app matches on before sending HTTP requests, and `ip` becomes an HTTP
  /// host as well as a URL the menu opens (`http://\(device.ip)`). A malformed record must be
  /// dropped here, not reach the network layer.
  public static func parse(
    _ dict: [String: String]
  ) -> Result<SennheiserNetworkDevice, ParseFailure> {
    var fields: [String: String] = [:]
    for key in ["uuid", "serial", "name", "ip"] {
      let value = (dict[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { return .failure(.missingField(key)) }
      fields[key] = value
    }
    let uuid = fields["uuid"]!
    let serial = fields["serial"]!
    let name = fields["name"]!
    let ip = fields["ip"]!

    guard isValidUUID(uuid) else { return .failure(.malformedUUID(uuid)) }
    guard isValidIPv4Address(ip) else { return .failure(.malformedIPv4Address(ip)) }
    return .success(SennheiserNetworkDevice(uuid: uuid, serial: serial, name: name, ip: ip))
  }

  /// Observed shape is `ambeosoundbarmini-2ccbc823-81a7-...`; keep it to characters that are safe
  /// inside a URL query and reject anything that could smuggle in a path, host, or escape.
  static func isValidUUID(_ string: String) -> Bool {
    guard (8...128).contains(string.count) else { return false }
    return string.allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
    }
  }

  /// Four decimal octets (no leading zeros, so `192.168.020.1` is not accepted with a hidden
  /// meaning), and not an address that cannot be a soundbar on the local network.
  static func isValidIPv4Address(_ string: String) -> Bool {
    let octets = string.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return false }
    var first = 0
    for (index, part) in octets.enumerated() {
      guard part.count >= 1, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        return false
      }
      if part.count > 1, part.first == "0" { return false }
      guard let value = Int(part), value <= 255 else { return false }
      if index == 0 { first = value }
    }
    guard first != 0, first != 127 else { return false }
    return true
  }
}

public enum SennheiserDiscovery {
  /// One serial queue is shared by every browse session. NWBrowser documents queue sharing as
  /// supported, and creating a fresh serial queue per `browse()` only churns the pool (the app
  /// starts dozens of browse sessions per run).
  private static let callbackQueue = DispatchQueue(label: "io.github.jhorology.SennheiserDiscovery")

  /// Logger interpolation cannot take an arbitrary enum, so spell the rejection out.
  private static func describe(_ failure: SennheiserNetworkDevice.ParseFailure) -> String {
    switch failure {
    case .missingField(let field): return "missing TXT field \(field)"
    case .malformedUUID(let value): return "malformed uuid \"\(value)\""
    case .malformedIPv4Address(let value): return "malformed ip \"\(value)\""
    }
  }

  public static func browse() -> AsyncStream<[SennheiserNetworkDevice]> {
    AsyncStream { continuation in
      let browser = NWBrowser(
        for: .bonjourWithTXTRecord(type: "_sennheiser._tcp.", domain: "local."),
        using: .tcp
      )

      browser.browseResultsChangedHandler = { results, _ in
        var devices: [SennheiserNetworkDevice] = []
        for result in results {
          guard case let .bonjour(txtRecord) = result.metadata else { continue }
          switch SennheiserNetworkDevice.parse(txtRecord.dictionary) {
          case let .success(device): devices.append(device)
          case let .failure(failure):
            Logger.network.warning("Ignoring mDNS record: \(describe(failure))")
          }
        }
        Logger.network.trace("Discovered devices:\(devices)")
        continuation.yield(devices)
      }

      continuation.onTermination = { @Sendable _ in
        browser.cancel()
        Logger.network.info("NWBrowser session cancelled.")
      }

      browser.start(queue: Self.callbackQueue)
      Logger.network.info("NWBrowser started.")
    }
  }
}
