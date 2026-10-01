import Foundation

/// Records only successful hardware changes, independently for each soundbar.
@MainActor
public final class AtmosBoostLedger {
  private let defaults: UserDefaults
  private let key: String
  private var amounts: [String: Int]

  public init(defaults: UserDefaults = .standard, key: String) {
    self.defaults = defaults
    self.key = key
    amounts = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
  }

  public func amount(for uid: String) -> Int { amounts[uid] ?? 0 }

  public func record(_ amount: Int, for uid: String) {
    guard !uid.isEmpty else { return }
    amounts[uid] = max(0, amount)
    defaults.set(amounts, forKey: key)
  }
}
