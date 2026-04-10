import Foundation

@propertyWrapper
public struct Atomic<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: Value

  public init(wrappedValue: Value) {
    self._value = wrappedValue
  }

  public var wrappedValue: Value {
    get { lock.withLock { _value } }
    set { lock.withLock { _value = newValue } }
  }
}
