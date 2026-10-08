import CoreAudio
import XCTest

@testable import AmbeoCore

final class AudioDeviceSelectionTests: XCTestCase {
  private let uid = "10AC4EA2-0000-0000-0623-010380462878"

  private func device(
    _ id: UInt32,
    _ uid: String,
    transport: UInt32 = kAudioDeviceTransportTypeHDMI
  )
    -> AudioDevice
  {
    AudioDevice(id: id, uid: uid, name: "AW3225QF", transportType: transport)
  }

  func testRecoversObservedHDMISuffixAndSubsequentChanges() {
    let connected = device(96, uid + "_00000040")
    XCTAssertEqual(AudioDeviceSelection.resolve(uid: uid, in: [connected]), connected)
    XCTAssertEqual(
      AudioDeviceSelection.resolve(uid: uid + "_00000020", in: [connected]),
      connected
    )
    let unsuffixed = device(97, uid, transport: kAudioDeviceTransportTypeDisplayPort)
    XCTAssertEqual(
      AudioDeviceSelection.resolve(uid: connected.uid, in: [unsuffixed]),
      unsuffixed
    )
  }

  func testExactUIDTakesPriorityEvenWhenDisplayIdentityIsAmbiguous() {
    let exact = device(1, uid)
    XCTAssertEqual(
      AudioDeviceSelection.resolve(uid: uid, in: [device(2, uid + "_00000040"), exact]),
      exact
    )
  }

  func testAmbiguousDisconnectedAndDifferentDisplaysAreNotSelected() {
    XCTAssertNil(
      AudioDeviceSelection.resolve(
        uid: uid,
        in: [device(1, uid + "_00000040"), device(2, uid + "_00000020")]
      )
    )
    XCTAssertNil(AudioDeviceSelection.resolve(uid: uid, in: []))
    XCTAssertNil(
      AudioDeviceSelection.resolve(
        uid: uid,
        in: [device(1, "10AC07D1-0000-0000-1E1E-0104B5462878")]
      )
    )
    XCTAssertNil(AudioDeviceSelection.resolve(uid: "", in: [device(1, uid)]))
  }

  func testOtherTransportsAndOpaqueUIDsRequireExactMatch() {
    XCTAssertNil(
      AudioDeviceSelection.resolve(
        uid: uid,
        in: [device(1, uid + "_00000040", transport: kAudioDeviceTransportTypeUSB)]
      )
    )
    for suffix in ["_40", "_0000004Z", "_00000040_extra", "_"] {
      XCTAssertNil(AudioDeviceSelection.resolve(uid: uid, in: [device(1, uid + suffix)]))
    }
    XCTAssertNil(
      AudioDeviceSelection.resolve(uid: "driver-output", in: [device(1, "driver-output_00000040")])
    )
    let usb = device(1, "RMEUSBDevice-192-72990454", transport: kAudioDeviceTransportTypeUSB)
    XCTAssertEqual(AudioDeviceSelection.resolve(uid: usb.uid, in: [usb]), usb)
  }
}
