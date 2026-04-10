import Foundation
import Logging
import Network

public struct SennheiserNetworkDevice: Sendable, Identifiable, Hashable, Codable {
  public var id: String { uuid }
  public let uuid: String  // device uuid
  public let serial: String  // device serial number
  public let name: String  // user friendly name (Google/Apple Home device name)
  public let ip: String  // ipv4 address

  init?(withDict dict: [String: String]) {
    guard let uuid = dict["uuid"],
      let serial = dict["serial"],
      let name = dict["name"],
      let ip = dict["ip"]
    else {
      return nil
    }
    self.uuid = uuid
    self.serial = serial
    self.name = name
    self.ip = ip
  }
}

public enum SennheiserDiscovery {

  public static func browse() -> AsyncStream<[SennheiserNetworkDevice]> {
    AsyncStream { continuation in
      let browser = NWBrowser(
        for: .bonjourWithTXTRecord(type: "_sennheiser._tcp.", domain: "local."),
        using: .tcp
      )

      browser.browseResultsChangedHandler = { results, _ in
        let devices = results.compactMap { result -> SennheiserNetworkDevice? in
          // extract txtRecord
          if case let .bonjour(txtRecord) = result.metadata {
            return SennheiserNetworkDevice(withDict: txtRecord.dictionary)
          }
          return nil
        }
        Logger.network.trace("Discovered devices:\(devices)")
        continuation.yield(devices)
      }

      continuation.onTermination = { @Sendable _ in
        browser.cancel()
        Logger.network.info("NWBrowser session cancelled.")
      }

      let queue = DispatchQueue(label: "io.github.jhorology.SennheiserDiscovery")
      browser.start(queue: queue)
      Logger.network.info("NWBrowser started.")
    }
  }
}
