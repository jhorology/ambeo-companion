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
  private class Context: @unchecked Sendable {
    let shouldIntercept: @Sendable (SystemEvent) -> Bool
    let continuation: AsyncStream<SystemEvent>.Continuation
    var runLoop: CFRunLoop?

    init(
      shouldIntercept: @escaping @Sendable (SystemEvent) -> Bool,
      continuation: AsyncStream<SystemEvent>.Continuation
    ) {
      self.shouldIntercept = shouldIntercept
      self.continuation = continuation
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

      nonisolated(unsafe) let safeEventTap = eventTap
      nonisolated(unsafe) let safeBridge = bridge
      nonisolated(unsafe) let runLoopSource = CFMachPortCreateRunLoopSource(
        kCFAllocatorDefault,
        safeEventTap,
        0
      )

      let thread = Thread {
        let currentRL = CFRunLoopGetCurrent()
        context.runLoop = currentRL
        CFRunLoopAddSource(currentRL, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: safeEventTap, enable: true)
        CFRunLoopRun()
      }
      thread.name = "SystemEventMonitorThread"
      thread.start()
      Logger.lifecycle.trace("System event monitor has started.")

      continuation.onTermination = { @Sendable _ in
        if let rl = context.runLoop {
          CFRunLoopStop(rl)
        }
        CGEvent.tapEnable(tap: safeEventTap, enable: false)
        Unmanaged<Context>.fromOpaque(safeBridge).release()
        Logger.lifecycle.trace("System event monitor has terminated.")
      }
    }
  }
}
