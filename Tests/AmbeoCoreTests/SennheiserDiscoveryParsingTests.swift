import Foundation
import Testing

@testable import AmbeoCore

@Suite("Sennheiser TXT Record Parsing") struct SennheiserDiscoveryParsingTests {
  /// Observed on the real soundbar (Logs/ambeo-companion.log).
  private let realRecord: [String: String] = [
    "uuid": "ambeosoundbarmini-2ccbc823-81a7-494e-a9a8-decccfa345b4", "serial": "000034826737",
    "name": "サウンドバー", "ip": "192.168.0.20",
  ]

  private func parse(_ dict: [String: String]) -> SennheiserNetworkDevice.ParseFailure? {
    switch SennheiserNetworkDevice.parse(dict) {
    case .success: return nil
    case .failure(let failure): return failure
    }
  }

  @Test("The record a real soundbar sends is accepted unchanged") func realRecordAccepted() {
    let device = SennheiserNetworkDevice(withDict: realRecord)
    #expect(device?.uuid == realRecord["uuid"])
    #expect(device?.serial == realRecord["serial"])
    #expect(device?.name == "サウンドバー")
    #expect(device?.ip == "192.168.0.20")
  }

  @Test("Surrounding whitespace is trimmed, not treated as part of the value")
  func whitespaceTrimmed() {
    var dict = realRecord
    dict["ip"] = "  192.168.0.20\n"
    dict["uuid"] = " \(realRecord["uuid"]!)"
    #expect(SennheiserNetworkDevice(withDict: dict)?.ip == "192.168.0.20")
  }

  @Test("Every missing, empty, or blank field is reported by name") func missingFields() {
    for key in ["uuid", "serial", "name", "ip"] {
      var absent = realRecord
      absent.removeValue(forKey: key)
      #expect(parse(absent) == .missingField(key), "missing \(key)")

      var blank = realRecord
      blank[key] = "   "
      #expect(parse(blank) == .missingField(key), "blank \(key)")
    }
  }

  @Test("A uuid that cannot be a soundbar id is rejected") func malformedUUIDs() {
    for bad in ["bad uuid", "a/b/c", "uuid%20x", "short", "日本語uuid"] {
      var dict = realRecord
      dict["uuid"] = bad
      #expect(parse(dict) == .malformedUUID(bad), "accepted uuid \(bad)")
    }
  }

  @Test("An ip that cannot address a soundbar on the LAN is rejected") func malformedAddresses() {
    for bad in [
      "192.168.0.256", "192.168.0", "1.2.3.4.5", "evil.example.com", "127.0.0.1", "0.0.0.0",
      "192.168.020.1", "::1", "192.168.0.20/path", "999.1.1.1",
    ] {
      var dict = realRecord
      dict["ip"] = bad
      #expect(parse(dict) == .malformedIPv4Address(bad), "accepted ip \(bad)")
    }
  }

  @Test("Valid addresses at the edges are accepted") func validAddresses() {
    for good in ["10.0.0.1", "169.254.1.1", "192.168.0.20", "255.255.255.255"] {
      var dict = realRecord
      dict["ip"] = good
      #expect(SennheiserNetworkDevice(withDict: dict)?.ip == good, "rejected ip \(good)")
    }
  }
}
