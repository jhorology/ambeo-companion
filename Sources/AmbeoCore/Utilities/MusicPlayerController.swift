import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Foundation
import Logging
import os

public enum MusicAutomationPermissionStatus: Sendable, Equatable {
  case granted
  case notDetermined
  case denied
  case musicNotRunning

  public var isGranted: Bool { self == .granted }
}

public protocol MusicPlayerControlling: Sendable {
  func isRunning() -> Bool
  func permissionStatus(askUserIfNeeded: Bool) -> MusicAutomationPermissionStatus
  func isPlaying() async -> Bool
  @discardableResult func rewindToStart() async -> Bool
  /// Seeds the cached playback state from `Music.app`. A no-op for players without a cache.
  func refreshPlaybackStateInBackground()
}

extension MusicPlayerControlling { public func refreshPlaybackStateInBackground() {} }

public final class MusicPlayerController: MusicPlayerControlling, @unchecked Sendable {
  public static let shared = MusicPlayerController()
  public static let musicBundleIdentifier = "com.apple.Music"

  // Music.app scripting codes (`sdef /System/Applications/Music.app`).
  private static let playerStateProperty = fourCC("pPlS")
  private static let playingState = fourCC("kPSP")
  private static let playerPositionProperty = fourCC("pPos")

  /// How long a background query waits for `Music.app` to answer before giving up.
  private static let replyTimeout: TimeInterval = 2.0

  /// Serial queue for blocking Apple Event round trips so callers never wait on `Music.app`.
  ///
  /// Raw Apple Events (`AESendMessage`) are used instead of `NSAppleScript`: while waiting for a
  /// reply, `NSAppleScript` pumps the HIToolbox event loop, and off the main thread that runs the
  /// *main* run loop's observers on this queue. SwiftUI then rebuilt the main menu off-main and
  /// AppKit aborted the app ("Main menu contents may only be modified from the main thread").
  private let scriptQueue = DispatchQueue(
    label: "io.github.jhorology.ambeo-companion.MusicAppleScript",
    qos: .userInteractive
  )

  /// Real-time playback state cached from `com.apple.Music.playerInfo` distributed notifications
  /// so format transitions never block waiting for `Music.app`'s main thread during CoreAudio hog switches.
  private let cachedIsPlaying = OSAllocatedUnfairLock<Bool?>(initialState: nil)

  public init() {
    setupNotifications()
    refreshPlaybackStateInBackground()
  }

  private func setupNotifications() {
    DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.Music.playerInfo"),
      object: nil,
      queue: nil
    ) { [weak self] notification in
      let info = notification.userInfo
      let state = info?["Player State"] as? String
      let trackName = info?["Name"] as? String
      let totalTimeMs = info?["Total Time"] as? Int
      let playing = (state == "Playing")
      self?.cachedIsPlaying.withLock { $0 = playing }
      Logger.audio.debug(
        "Music.app playerInfo notification: state=\(state ?? "nil"), isPlaying=\(playing), track=\"\(trackName ?? "")\", totalTimeMs=\(totalTimeMs ?? 0)"
      )
    }

    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication, app.bundleIdentifier == Self.musicBundleIdentifier
      else { return }
      self?.cachedIsPlaying.withLock { $0 = false }
    }
  }

  /// Queries `Music.app` playback state in the background when idle so `cachedIsPlaying` is seeded
  /// even if `Music.app` was already playing before `AmbeoCompanion` launched.
  public func refreshPlaybackStateInBackground() {
    guard isRunning(), permissionStatus(askUserIfNeeded: false) == .granted else { return }
    scriptQueue.async { [weak self] in
      guard let self, self.isRunning(), self.permissionStatus(askUserIfNeeded: false) == .granted
      else { return }
      let playing = self.queryIsPlayingOnQueue(action: "seed playback state")
      self.cachedIsPlaying.withLock { current in if current == nil { current = playing } }
    }
  }

  public func isRunning() -> Bool {
    NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleIdentifier)
      .contains { !$0.isTerminated }
  }

  public func permissionStatus(askUserIfNeeded: Bool) -> MusicAutomationPermissionStatus {
    guard isRunning() else { return .musicNotRunning }
    let target = NSAppleEventDescriptor(bundleIdentifier: Self.musicBundleIdentifier)
    let status = AEDeterminePermissionToAutomateTarget(
      target.aeDesc,
      typeWildCard,
      typeWildCard,
      askUserIfNeeded
    )
    if askUserIfNeeded {
      Logger.audio.info(
        "MusicPlayerController: AEDeterminePermissionToAutomateTarget(askUserIfNeeded: true) returned status=\(status)"
      )
    }
    switch status {
    case noErr: return .granted
    case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
    case OSStatus(errAEEventNotPermitted): return .denied
    case OSStatus(procNotFound): return .musicNotRunning
    default:
      Logger.audio.debug("AEDeterminePermissionToAutomateTarget returned status=\(status)")
      return .denied
    }
  }

  /// Requests Automation permission for `Music.app`, falling back to executing a lightweight
  /// read-only AppleEvent if `AEDeterminePermissionToAutomateTarget` does not resolve the state.
  public func requestPermission() async -> MusicAutomationPermissionStatus {
    guard isRunning() else { return .musicNotRunning }
    let status = await Task.detached(priority: .userInitiated) {
      self.permissionStatus(askUserIfNeeded: true)
    }.value
    if status == .granted {
      refreshPlaybackStateInBackground()
      return .granted
    }

    return await withCheckedContinuation { continuation in
      scriptQueue.async { [weak self] in
        guard let self, self.isRunning() else {
          continuation.resume(returning: .musicNotRunning)
          return
        }
        // Interactive so macOS may show the Automation consent prompt for this read-only event.
        let playing = self.queryIsPlayingOnQueue(
          action: "request Automation permission",
          options: [.waitForReply, .canInteract],
          timeout: 60
        )
        let updatedStatus = self.permissionStatus(askUserIfNeeded: false)
        if updatedStatus == .granted { self.cachedIsPlaying.withLock { $0 = playing } }
        Logger.audio.info(
          "MusicPlayerController: Automation permission request finished with status=\(String(describing: updatedStatus))"
        )
        continuation.resume(returning: updatedStatus)
      }
    }
  }

  /// Launches `Music.app` in the background if it is not currently running so macOS can register
  /// or prompt for Automation permission against `com.apple.Music`.
  public func ensureMusicRunningForPermissionPrompt() async -> Bool {
    if isRunning() { return true }
    guard
      let appURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: Self.musicBundleIdentifier
      )
    else {
      Logger.lifecycle.warning(
        "Music.app not found for bundle identifier \(Self.musicBundleIdentifier)"
      )
      return false
    }

    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.addsToRecentItems = false
    config.hides = true

    do { _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config) } catch
    {
      Logger.lifecycle.warning(
        "Failed to launch Music.app for Automation permission prompt: \(error.localizedDescription)"
      )
      return false
    }

    for _ in 0..<25 {
      if isRunning(), permissionStatus(askUserIfNeeded: false) != .musicNotRunning { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return isRunning()
  }

  public func isPlaying() async -> Bool {
    guard isRunning() else {
      cachedIsPlaying.withLock { $0 = false }
      return false
    }

    let status = permissionStatus(askUserIfNeeded: false)
    switch status {
    case .musicNotRunning: return false
    case .denied:
      Logger.audio.warning("Stealth Rewind skipped: Music.app Automation permission is denied.")
      return false
    case .notDetermined:
      // Never prompt here: this runs mid format transition, and a consent dialog would stall the
      // format handling until the user answers. The Permissions window requests access instead.
      Logger.audio.info(
        "Stealth Rewind skipped: Music.app Automation permission has not been requested yet."
      )
      return false
    case .granted: break
    }

    // Fast path: return cached state from `com.apple.Music.playerInfo` immediately (0ms)
    // so we do not block on AppleEvents while Music.app's main thread is switching CoreAudio formats.
    if let cached = cachedIsPlaying.withLock({ $0 }) { return cached }

    return await withCheckedContinuation { continuation in
      scriptQueue.async { [weak self] in
        guard let self, self.isRunning() else {
          continuation.resume(returning: false)
          return
        }
        let playing = self.queryIsPlayingOnQueue(action: "check playback state")
        self.cachedIsPlaying.withLock { $0 = playing }
        continuation.resume(returning: playing)
      }
    }
  }

  @discardableResult public func rewindToStart() async -> Bool {
    guard isRunning(), permissionStatus(askUserIfNeeded: false) == .granted else { return false }
    return await withCheckedContinuation { continuation in
      scriptQueue.async { [weak self] in
        guard let self, self.isRunning(), self.permissionStatus(askUserIfNeeded: false) == .granted
        else {
          continuation.resume(returning: false)
          return
        }
        let start = ContinuousClock.now
        let action = "rewind player position to 0"
        let prevPos = self.sendOnQueue(self.getEvent(Self.playerPositionProperty), action: action)?
          .doubleValue
        let setEvent = self.makeEvent(AEEventID(kAESetData))
        setEvent.setParam(
          Self.propertySpecifier(Self.playerPositionProperty),
          forKeyword: keyDirectObject
        )
        setEvent.setParam(NSAppleEventDescriptor(double: 0), forKeyword: AEKeyword(keyAEData))
        let succeeded = self.sendOnQueue(setEvent, action: action) != nil
        let elapsedMs = start.duration(to: ContinuousClock.now).millisecondsString
        Logger.audio.debug(
          "Music.app rewind Apple Event: prevPosition=\(String(format: "%.3f", prevPos ?? -1))s -> 0.000s (ipc=\(elapsedMs), success=\(succeeded))"
        )
        continuation.resume(returning: succeeded)
      }
    }
  }

  // MARK: - Apple Events

  /// Reads `player state` and reports whether it is `playing`. Must run on `scriptQueue`.
  private func queryIsPlayingOnQueue(
    action: String,
    options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract],
    timeout: TimeInterval = MusicPlayerController.replyTimeout
  ) -> Bool {
    let state = sendOnQueue(
      getEvent(Self.playerStateProperty),
      action: action,
      options: options,
      timeout: timeout
    )
    return state?.enumCodeValue == Self.playingState
  }

  private func makeEvent(_ eventID: AEEventID) -> NSAppleEventDescriptor {
    NSAppleEventDescriptor(
      eventClass: AEEventClass(kAECoreSuite),
      eventID: eventID,
      targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: Self.musicBundleIdentifier),
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
  }

  /// `get <property> of application "Music"`.
  private func getEvent(_ property: FourCharCode) -> NSAppleEventDescriptor {
    let event = makeEvent(AEEventID(kAEGetData))
    event.setParam(Self.propertySpecifier(property), forKeyword: keyDirectObject)
    return event
  }

  /// Object specifier for an application-level property (`property <code> of application`).
  private static func propertySpecifier(_ property: FourCharCode) -> NSAppleEventDescriptor {
    let spec = NSAppleEventDescriptor.record().coerce(
      toDescriptorType: DescType(typeObjectSpecifier)
    )!
    spec.setDescriptor(
      NSAppleEventDescriptor(typeCode: DescType(cProperty)),
      forKeyword: AEKeyword(keyAEDesiredClass)
    )
    spec.setDescriptor(
      NSAppleEventDescriptor(enumCode: DescType(formPropertyID)),
      forKeyword: AEKeyword(keyAEKeyForm)
    )
    spec.setDescriptor(
      NSAppleEventDescriptor(typeCode: property),
      forKeyword: AEKeyword(keyAEKeyData)
    )
    spec.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
    return spec
  }

  /// Sends `event` and returns the reply's direct object, or nil on any failure. A raw Apple
  /// Event never launches `Music.app` and blocks only this queue while it waits for the reply.
  private func sendOnQueue(
    _ event: NSAppleEventDescriptor,
    action: String,
    options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract],
    timeout: TimeInterval = MusicPlayerController.replyTimeout
  ) -> NSAppleEventDescriptor? {
    do {
      let reply = try event.sendEvent(options: options, timeout: timeout)
      if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)),
        error.int32Value != noErr
      {
        Logger.audio.warning(
          "MusicPlayerController: failed to \(action) (Apple Event error \(error.int32Value))"
        )
        return nil
      }
      return reply.paramDescriptor(forKeyword: keyDirectObject)
    } catch {
      Logger.audio.warning("MusicPlayerController: failed to \(action) (\(error))")
      return nil
    }
  }

  private static func fourCC(_ code: StaticString) -> FourCharCode {
    code.withUTF8Buffer { $0.reduce(0) { $0 << 8 | FourCharCode($1) } }
  }
}

extension Duration {
  public var millisecondsString: String {
    let ms = Double(components.seconds) * 1000.0 + Double(components.attoseconds) / 1e15
    return String(format: "%.1fms", ms)
  }
}
