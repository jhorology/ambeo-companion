import AppKit
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
  private final class Context: @unchecked Sendable {
    let shouldIntercept: @Sendable (SystemEvent) -> Bool
    let continuation: AsyncStream<SystemEvent>.Continuation
    /// Set once before the monitor thread starts; read only from that thread's callback.
    var eventTap: CFMachPort?

    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var stopped = false

    init(
      shouldIntercept: @escaping @Sendable (SystemEvent) -> Bool,
      continuation: AsyncStream<SystemEvent>.Continuation
    ) {
      self.shouldIntercept = shouldIntercept
      self.continuation = continuation
    }

    /// Called by the monitor thread. Returns false when the stream already ended.
    func attach(_ rl: CFRunLoop) -> Bool {
      lock.withLock {
        runLoop = rl
        return !stopped
      }
    }

    var isStopped: Bool { lock.withLock { stopped } }

    func stop() {
      let rl = lock.withLock {
        stopped = true
        return runLoop
      }
      if let rl { CFRunLoopStop(rl) }
    }
  }

  public static func events(
    shouldIntercept: @escaping @Sendable (SystemEvent) -> Bool
  ) -> AsyncStream<SystemEvent> {
    AsyncStream { continuation in
      let context = Context(shouldIntercept: shouldIntercept, continuation: continuation)
      let bridge = Unmanaged.passRetained(context).toOpaque()

      let callback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passRetained(event) }
        let ctx = Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue()

        // The system disables an active tap when callbacks are slow or input monitoring is revoked.
        switch type {
        case .tapDisabledByTimeout:
          Logger.lifecycle.warning("Media key event tap was disabled by timeout. Re-enabling.")
          if let tap = ctx.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
          return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
          Logger.lifecycle.warning(
            "Media key event tap was disabled by user input. Check Input Monitoring / Accessibility permissions."
          )
          if let tap = ctx.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
          return Unmanaged.passUnretained(event)
        default:
          break
        }

        if let nsEvent = NSEvent(cgEvent: event), let systemEvent = SystemEvent(from: nsEvent) {
          if ctx.shouldIntercept(systemEvent) {

            Logger.lifecycle.trace("System event [\(systemEvent)] should be intercepted.")

            ctx.continuation.yield(systemEvent)
            return nil
          }
        }

        Logger.lifecycle.trace("System event [\(event)] was ignored.")

        return Unmanaged.passRetained(event)
      }

      guard
        let eventTap = CGEvent.tapCreate(
          tap: .cgSessionEventTap,
          place: .headInsertEventTap,
          options: .defaultTap,
          eventsOfInterest: UInt64(1 << 14),
          callback: callback,
          userInfo: bridge
        )
      else {
        continuation.finish()
        Unmanaged<Context>.fromOpaque(bridge).release()
        return
      }
      context.eventTap = eventTap

      nonisolated(unsafe) let safeEventTap = eventTap
      nonisolated(unsafe) let safeBridge = bridge
      nonisolated(unsafe) let runLoopSource = CFMachPortCreateRunLoopSource(
        kCFAllocatorDefault,
        safeEventTap,
        0
      )

      // The thread owns the tap: it tears it down and releases the context only after its
      // run loop has exited, so the callback never sees a released context.
      let thread = Thread {
        if let currentRL = CFRunLoopGetCurrent(), context.attach(currentRL) {
          CFRunLoopAddSource(currentRL, runLoopSource, .commonModes)
          CGEvent.tapEnable(tap: safeEventTap, enable: true)
          // A CFRunLoopStop issued before the loop starts is lost, so re-check the flag periodically.
          while !context.isStopped {
            CFRunLoopRunInMode(.defaultMode, 1.0, false)
          }
          CFRunLoopRemoveSource(currentRL, runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: safeEventTap, enable: false)
        CFMachPortInvalidate(safeEventTap)
        Unmanaged<Context>.fromOpaque(safeBridge).release()
        Logger.lifecycle.trace("System event monitor thread has exited.")
      }
      thread.name = "SystemEventMonitorThread"
      thread.start()
      Logger.lifecycle.trace("System event monitor has started.")

      continuation.onTermination = { @Sendable _ in
        context.stop()
        Logger.lifecycle.trace("System event monitor has terminated.")
      }
    }
  }
}
