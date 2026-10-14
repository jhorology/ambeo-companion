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

  public var isGranted: Bool {
    self == .granted
  }
}

public protocol MusicPlayerControlling: Sendable {
  func isRunning() -> Bool
  func permissionStatus(askUserIfNeeded: Bool) -> MusicAutomationPermissionStatus
  func isPlaying() async -> Bool
  @discardableResult
  func rewindToStart() async -> Bool
}

public final class MusicPlayerController: MusicPlayerControlling, @unchecked Sendable {
  public static let shared = MusicPlayerController()
  public static let musicBundleIdentifier = "com.apple.Music"

  private static let isPlayingScriptSource = """
    tell application id "com.apple.Music"
      if it is running then
        return (player state is playing)
      end if
      return false
    end tell
    """

  private static let rewindScriptSource = """
    tell application id "com.apple.Music"
      if it is running then
        set prevPos to player position
        set player position to 0
        return prevPos
      end if
      return -1.0
    end tell
    """

  /// Dedicated serial queue for `NSAppleScript` compilation and execution (`NSAppleScript` is not thread-safe).
  private let scriptQueue = DispatchQueue(
    label: "io.github.jhorology.ambeo-companion.MusicAppleScript",
    qos: .userInteractive
  )
  private var compiledIsPlayingScript: NSAppleScript?
  private var compiledRewindScript: NSAppleScript?

  /// Real-time playback state cached from `com.apple.Music.playerInfo` distributed notifications
  /// so format transitions never block waiting for `Music.app`'s main thread during CoreAudio hog switches.
  private let cachedIsPlaying = OSAllocatedUnfairLock<Bool?>(initialState: nil)

  public init() {
    setupNotifications()
    scriptQueue.async { [weak self] in
      guard let self else { return }
      self.compiledIsPlayingScript = Self.compileScript(
        Self.isPlayingScriptSource,
        name: "isPlaying"
      )
      self.compiledRewindScript = Self.compileScript(
        Self.rewindScriptSource,
        name: "rewindToStart"
      )
    }
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
          as? NSRunningApplication,
        app.bundleIdentifier == Self.musicBundleIdentifier
      else { return }
      self?.cachedIsPlaying.withLock { $0 = false }
    }
  }

  /// Queries `Music.app` playback state in the background when idle so `cachedIsPlaying` is seeded
  /// even if `Music.app` was already playing before `AmbeoCompanion` launched.
  public func refreshPlaybackStateInBackground() {
    guard isRunning(), permissionStatus(askUserIfNeeded: false) == .granted else { return }
    scriptQueue.async { [weak self] in
      guard let self, self.isRunning(),
        self.permissionStatus(askUserIfNeeded: false) == .granted
      else { return }
      let playing = self.executeScriptOnQueue(
        &self.compiledIsPlayingScript,
        source: Self.isPlayingScriptSource,
        action: "seed playback state"
      )
      self.cachedIsPlaying.withLock { current in
        if current == nil {
          current = playing
        }
      }
    }
  }

  public func isRunning() -> Bool {
    NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleIdentifier)
      .contains { !$0.isTerminated }
  }

  public func permissionStatus(askUserIfNeeded: Bool) -> MusicAutomationPermissionStatus {
    guard isRunning() else {
      return .musicNotRunning
    }
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
    case noErr:
      return .granted
    case OSStatus(errAEEventWouldRequireUserConsent):
      return .notDetermined
    case OSStatus(errAEEventNotPermitted):
      return .denied
    case OSStatus(procNotFound):
      return .musicNotRunning
    default:
      Logger.audio.debug("AEDeterminePermissionToAutomateTarget returned status=\(status)")
      return .denied
    }
  }

  /// Requests Automation permission for `Music.app`, falling back to executing a lightweight
  /// read-only AppleEvent if `AEDeterminePermissionToAutomateTarget` does not resolve the state.
  public func requestPermission() async -> MusicAutomationPermissionStatus {
    guard isRunning() else {
      return .musicNotRunning
    }
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
        let playing = self.executeScriptOnQueue(
          &self.compiledIsPlayingScript,
          source: Self.isPlayingScriptSource,
          action: "request Automation permission"
        )
        let updatedStatus = self.permissionStatus(askUserIfNeeded: false)
        if updatedStatus == .granted {
          self.cachedIsPlaying.withLock { $0 = playing }
        }
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
    if isRunning() {
      return true
    }
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

    do {
      _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    } catch {
      Logger.lifecycle.warning(
        "Failed to launch Music.app for Automation permission prompt: \(error.localizedDescription)"
      )
      return false
    }

    for _ in 0..<25 {
      if isRunning(), permissionStatus(askUserIfNeeded: false) != .musicNotRunning {
        return true
      }
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
    case .musicNotRunning:
      return false
    case .denied:
      Logger.audio.warning(
        "Stealth Rewind skipped: Music.app Automation permission is denied."
      )
      return false
    case .notDetermined:
      let prompted = await requestPermission()
      guard prompted == .granted else {
        Logger.audio.info(
          "Stealth Rewind skipped: Music.app Automation permission not granted (\(String(describing: prompted)))."
        )
        return false
      }
    case .granted:
      break
    }

    // Fast path: return cached state from `com.apple.Music.playerInfo` immediately (0ms)
    // so we do not block on AppleEvents while Music.app's main thread is switching CoreAudio formats.
    if let cached = cachedIsPlaying.withLock({ $0 }) {
      return cached
    }

    return await withCheckedContinuation { continuation in
      scriptQueue.async { [weak self] in
        guard let self, self.isRunning() else {
          continuation.resume(returning: false)
          return
        }
        let playing = self.executeScriptOnQueue(
          &self.compiledIsPlayingScript,
          source: Self.isPlayingScriptSource,
          action: "check playback state"
        )
        self.cachedIsPlaying.withLock { $0 = playing }
        continuation.resume(returning: playing)
      }
    }
  }

  @discardableResult
  public func rewindToStart() async -> Bool {
    guard isRunning(), permissionStatus(askUserIfNeeded: false) == .granted else {
      return false
    }
    return await withCheckedContinuation { continuation in
      scriptQueue.async { [weak self] in
        guard let self, self.isRunning(),
          self.permissionStatus(askUserIfNeeded: false) == .granted
        else {
          continuation.resume(returning: false)
          return
        }
        let start = ContinuousClock.now
        guard
          let descriptor = self.executeScriptDescriptorOnQueue(
            &self.compiledRewindScript,
            source: Self.rewindScriptSource,
            action: "rewind player position to 0"
          )
        else {
          continuation.resume(returning: false)
          return
        }
        let prevPos = descriptor.doubleValue
        let elapsedMs = start.duration(to: ContinuousClock.now).millisecondsString
        let succeeded = prevPos >= 0
        Logger.audio.debug(
          "Music.app rewind AppleScript: prevPosition=\(String(format: "%.3f", prevPos))s -> 0.000s (ipc=\(elapsedMs), success=\(succeeded))"
        )
        continuation.resume(returning: succeeded)
      }
    }
  }

  private static func compileScript(_ source: String, name: String) -> NSAppleScript? {
    guard let script = NSAppleScript(source: source) else { return nil }
    var errorDict: NSDictionary?
    guard script.compileAndReturnError(&errorDict) else {
      Logger.audio.warning(
        "MusicPlayerController: failed to compile AppleScript '\(name)' (\(String(describing: errorDict)))"
      )
      return nil
    }
    return script
  }

  private func executeScriptOnQueue(
    _ compiledScript: inout NSAppleScript?,
    source: String,
    action: String
  ) -> Bool {
    guard
      let descriptor = executeScriptDescriptorOnQueue(
        &compiledScript,
        source: source,
        action: action
      )
    else {
      return false
    }
    return descriptor.booleanValue
  }

  private func executeScriptDescriptorOnQueue(
    _ compiledScript: inout NSAppleScript?,
    source: String,
    action: String
  ) -> NSAppleEventDescriptor? {
    if compiledScript == nil {
      compiledScript = Self.compileScript(source, name: action)
    }
    guard let script = compiledScript else {
      Logger.audio.warning("MusicPlayerController: AppleScript unavailable for \(action)")
      return nil
    }
    var errorDict: NSDictionary?
    let descriptor = script.executeAndReturnError(&errorDict)
    if let errorDict {
      Logger.audio.warning(
        "MusicPlayerController: failed to \(action) (\(errorDict))"
      )
      return nil
    }
    return descriptor
  }
}

extension Duration {
  var millisecondsString: String {
    let ms = Double(components.seconds) * 1000.0 + Double(components.attoseconds) / 1e15
    return String(format: "%.1fms", ms)
  }
}
