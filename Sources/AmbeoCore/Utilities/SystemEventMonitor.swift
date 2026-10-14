import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Logging

public struct SystemEvent: Sendable {
  public let type: EventType
  public let isDown: Bool
  public let modifiers: NSEvent.ModifierFlags
  let rawData1: Int

  public enum EventType: Sendable {
    case power(PowerKey)
    case auxMouse(button: Int)
    case media(MediaKey)
    case unknown(subtype: Int16)
  }

  public enum PowerKey: Int, Sendable {
    case power = 1
    case sleep = 2
    case restart = 3
    case shutDown = 4
  }

  public enum MediaKey: Int, Sendable {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case capsLock = 4
    case help = 5
    case mute = 7
    case upArrow = 8
    case downArrow = 9
    case numLock = 10
    case contrastUp = 11
    case contrastDown = 12
    case launchPanel = 13
    case eject = 14
    case vidMirror = 15
    case play = 16
    case next = 17
    case previous = 18
    case fast = 19
    case rewind = 20
    case illuminationUp = 21
    case illuminationDown = 22
    case illuminationToggle = 23
  }
}

extension SystemEvent {
  init?(from event: NSEvent) {
    guard event.type == .systemDefined else { return nil }
    self.rawData1 = event.data1
    self.modifiers = event.modifierFlags
    let stateFlag = (event.data1 & 0xFF00) >> 8
    self.isDown = (stateFlag == 0xA)

    switch event.subtype.rawValue {
    case 1:
      let keyCode = event.data1 & 0xFF
      self.type = .power(PowerKey(rawValue: keyCode) ?? .power)
    case 7:
      let buttonNumber = (event.data1 & 0xFF0000) >> 16
      self.type = .auxMouse(button: buttonNumber)
    case 8:
      let keyCode = (event.data1 & 0xFF0000) >> 16
      if let key = MediaKey(rawValue: keyCode) {
        self.type = .media(key)
      } else {
        self.type = .unknown(subtype: 8)
      }
    default:
      self.type = .unknown(subtype: Int16(event.subtype.rawValue))
    }
  }
}

// MARK: - Monitor
public struct SystemEventMonitor {
  final class Context: @unchecked Sendable {
    let shouldIntercept: @Sendable (SystemEvent) -> Bool
    let continuation: AsyncStream<SystemEvent>.Continuation

    private let lock = NSLock()
    private var stopped = false
    private var needsReenable = false

    init(
      shouldIntercept: @escaping @Sendable (SystemEvent) -> Bool,
      continuation: AsyncStream<SystemEvent>.Continuation
    ) {
      self.shouldIntercept = shouldIntercept
      self.continuation = continuation
    }

    var isStopped: Bool { lock.withLock { stopped } }

    // Cancellation can run on the main actor. Only change a flag here: stopping a
    // run loop synchronously can wait for a callback blocked inside WindowServer.
    func stop() {
      lock.withLock { stopped = true }
    }

    func handleDisabledEvent(_ type: CGEventType) {
      switch type {
      case .tapDisabledByUserInput:
        // Never undo a user-requested disable, including permission revocation.
        stop()
        continuation.finish()
      case .tapDisabledByTimeout:
        // Defer WindowServer calls until the callback has returned.
        lock.withLock { needsReenable = true }
      default:
        break
      }
    }

    func takeReenableRequest() -> Bool {
      lock.withLock {
        defer { needsReenable = false }
        return needsReenable && !stopped
      }
    }
  }

  public static func events(
    shouldIntercept: @escaping @Sendable (SystemEvent) -> Bool
  ) -> AsyncStream<SystemEvent> {
    AsyncStream { continuation in
      let context = Context(shouldIntercept: shouldIntercept, continuation: continuation)

      let callback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let ctx = Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
          ctx.handleDisabledEvent(type)
          return Unmanaged.passUnretained(event)
        }
        guard !ctx.isStopped else { return Unmanaged.passUnretained(event) }

        if let nsEvent = NSEvent(cgEvent: event), let systemEvent = SystemEvent(from: nsEvent) {
          if ctx.shouldIntercept(systemEvent) {

            Logger.lifecycle.trace("System event [\(systemEvent)] should be intercepted.")

            ctx.continuation.yield(systemEvent)
            return nil
          }
        }

        Logger.lifecycle.trace("System event [\(event)] was ignored.")

        return Unmanaged.passUnretained(event)
      }

      // All Quartz operations belong to this thread, including creation and
      // destruction. A TCC/WindowServer stall must not block the UI actor.
      let thread = Thread {
        defer { continuation.finish() }
        guard !context.isStopped, AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
          return
        }
        let bridge = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<Context>.fromOpaque(bridge).release() }
        guard
          let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: UInt64(1 << 14),
            callback: callback,
            userInfo: bridge
          )
        else { return }
        defer {
          CGEvent.tapEnable(tap: eventTap, enable: false)
          CFMachPortInvalidate(eventTap)
          Logger.lifecycle.trace("System event monitor thread has exited.")
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0),
          let runLoop = CFRunLoopGetCurrent()
        else { return }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        defer { CFRunLoopRemoveSource(runLoop, source, .commonModes) }

        // Revocation can occur without a tap-disabled callback. Check here rather
        // than waiting for the UI's permission poll or the next media key.
        while !context.isStopped {
          guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            context.stop()
            break
          }
          if context.takeReenableRequest() {
            CGEvent.tapEnable(tap: eventTap, enable: true)
          }
          if CFRunLoopRunInMode(.defaultMode, 0.25, false) == .finished { break }
        }
      }

      thread.name = "SystemEventMonitorThread"
      continuation.onTermination = { @Sendable _ in
        context.stop()
        Logger.lifecycle.trace("System event monitor has terminated.")
      }
      thread.start()
      Logger.lifecycle.trace("System event monitor has started.")
    }
  }
}
