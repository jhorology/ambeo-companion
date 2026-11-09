import Foundation
import Testing

@testable import AmbeoCompanion

@Suite("Volume Adjustment Math") struct VolumeAdjustmentTests {
  @Test("Values clamp into the device range") func clamping() {
    #expect(VolumeAdjustment.clamped(50, min: 0, max: 100) == 50)
    #expect(VolumeAdjustment.clamped(140, min: 0, max: 100) == 100)
    #expect(VolumeAdjustment.clamped(-5, min: 0, max: 100) == 0)
    #expect(VolumeAdjustment.clamped(30, min: 40, max: 60) == 40)
  }

  @Test("A partial or absent edit range falls back to the documented defaults") func defaults() {
    // Firmware has been observed sending only some of min / max / step.
    #expect(VolumeAdjustment.clamped(150, min: nil, max: nil) == 100)
    #expect(VolumeAdjustment.clamped(150, min: 0, max: nil) == 100)
    #expect(VolumeAdjustment.clamped(-3, min: nil, max: nil) == 0)
    #expect(VolumeAdjustment.clamped(70, min: nil, max: 60) == 60)
    #expect(VolumeAdjustment.defaultStep == 1)
  }

  @Test("A nonsensical range (min above max) yields the lower bound instead of looping")
  func degenerateRange() { #expect(VolumeAdjustment.clamped(50, min: 80, max: 20) == 80) }

  @Test("The applied delta is what the device accepted, not what was requested")
  func appliedDeltaIsClamped() {
    // Boosting near the ceiling must record only the headroom, never the full +10.
    let nearTop = VolumeAdjustment.change(from: 95, delta: 10, min: 0, max: 100)
    #expect(nearTop.newValue == 100)
    #expect(nearTop.appliedDelta == 5)

    // Reverting near the floor likewise.
    let nearBottom = VolumeAdjustment.change(from: 3, delta: -10, min: 0, max: 100)
    #expect(nearBottom.newValue == 0)
    #expect(nearBottom.appliedDelta == -3)

    // Already at the edge: nothing was applied.
    let noRoom = VolumeAdjustment.change(from: 100, delta: 10, min: 0, max: 100)
    #expect(noRoom.appliedDelta == 0)

    let normal = VolumeAdjustment.change(from: 40, delta: 25, min: 0, max: 100)
    #expect(normal == VolumeAdjustment.Change(newValue: 65, appliedDelta: 25))
  }

  @Test("The OSD gauge spans the device range and stays inside 0...1") func gauge() {
    #expect(VolumeAdjustment.gauge(value: 0, min: 0, max: 100) == 0)
    #expect(VolumeAdjustment.gauge(value: 100, min: 0, max: 100) == 1)
    #expect(VolumeAdjustment.gauge(value: 50, min: 0, max: 100) == 0.5)
    #expect(VolumeAdjustment.gauge(value: 30, min: 20, max: 40) == 0.5)
    #expect(VolumeAdjustment.gauge(value: 120, min: 0, max: 100) == 1)
    #expect(VolumeAdjustment.gauge(value: -10, min: 0, max: 100) == 0)
    // A zero-width range must not divide by zero.
    #expect(VolumeAdjustment.gauge(value: 5, min: 5, max: 5) == 0)
    #expect(VolumeAdjustment.gauge(value: 5, min: nil, max: nil) == 0.05)
  }
}
