import Foundation

/// Volume arithmetic shared by the media-key handler and Atmos Boost.
///
/// AMBEO reports volume as an absolute count with a firmware-provided range. The range arrives in
/// the endpoint's `edit` fields, which firmware has been observed to send as strings (`"1"`), as
/// numbers (`1`), and sometimes partially - so callers pass optionals and the defaults live here.
public enum VolumeAdjustment {
  public static let defaultMin = 0
  public static let defaultMax = 100
  public static let defaultStep = 1

  /// One volume write: the value to send, and what actually changed relative to `current`.
  public struct Change: Equatable, Sendable {
    public let newValue: Int
    /// Clamped result of the request. Zero means the device was already at the edge of its range,
    /// which callers must not record as a boost.
    public let appliedDelta: Int

    public init(newValue: Int, appliedDelta: Int) {
      self.newValue = newValue
      self.appliedDelta = appliedDelta
    }
  }

  public static func clamped(_ candidate: Int, min: Int?, max: Int?) -> Int {
    let lower = min ?? defaultMin
    let upper = max ?? defaultMax
    guard lower <= upper else { return lower }  // a range we cannot make sense of
    return Swift.max(lower, Swift.min(upper, candidate))
  }

  public static func change(from current: Int, delta: Int, min: Int?, max: Int?) -> Change {
    let newValue = clamped(current + delta, min: min, max: max)
    return Change(newValue: newValue, appliedDelta: newValue - current)
  }

  /// The OSD gauge is 0...1 across the device range.
  public static func gauge(value: Int, min: Int?, max: Int?) -> Double {
    let lower = min ?? defaultMin
    let upper = max ?? defaultMax
    guard upper > lower else { return 0 }
    return Swift.max(0, Swift.min(1, Double(value - lower) / Double(upper - lower)))
  }
}
