import AmbeoCore
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics

/// UI names change in macOS 27; the underlying Accessibility API and pane anchor do not.
enum MediaKeyPermission: CaseIterable, Identifiable {
  case accessibility
  case inputMonitoring
  case musicAutomation

  var id: Self { self }

  var title: String {
    switch self {
    case .accessibility:
      if #available(macOS 27, *) { return "Device Control and Data Access" }
      return "Accessibility"
    case .inputMonitoring:
      return "Input Monitoring"
    case .musicAutomation:
      return "Automation (Music.app)"
    }
  }

  var explanation: String {
    switch self {
    case .accessibility:
      return
        "Lets Ambeo Companion intercept volume and mute keys and prevent macOS from handling them twice."
    case .inputMonitoring:
      return "Lets Ambeo Companion receive media keys while you use other apps."
    case .musicAutomation:
      return
        "Lets Ambeo Companion detect Apple Music playback and rewind tracks to 0:00 after an audio format switch (Stealth Rewind)."
    }
  }

  var isGranted: Bool {
    switch self {
    case .accessibility:
      return AXIsProcessTrusted()
    case .inputMonitoring:
      return CGPreflightListenEventAccess()
    case .musicAutomation:
      return MusicPlayerController.shared.permissionStatus(askUserIfNeeded: false).isGranted
    }
  }

  @MainActor
  func requestAndOpenSettings(onComplete: (@MainActor @Sendable () async -> Void)? = nil) {
    switch self {
    case .accessibility:
      if !isGranted {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
      }
      Self.openSystemSettings(anchor: "Privacy_Accessibility")

    case .inputMonitoring:
      if !isGranted {
        _ = CGRequestListenEventAccess()
      }
      Self.openSystemSettings(anchor: "Privacy_ListenEvent")

    case .musicAutomation:
      Task { @MainActor in
        let launched = await MusicPlayerController.shared.ensureMusicRunningForPermissionPrompt()
        if launched {
          let status = await Task.detached(priority: .userInitiated) {
            MusicPlayerController.shared.permissionStatus(askUserIfNeeded: true)
          }.value
          await onComplete?()
          if status != .granted {
            Self.openSystemSettings(anchor: "Privacy_Automation")
          }
        } else {
          Self.openSystemSettings(anchor: "Privacy_Automation")
        }
      }
    }
  }

  @MainActor
  private static func openSystemSettings(anchor: String) {
    for pane in [
      "com.apple.settings.PrivacySecurity.extension",
      "com.apple.preference.security",
    ] {
      if let url = URL(string: "x-apple.systempreferences:\(pane)?\(anchor)"),
        NSWorkspace.shared.open(url)
      {
        return
      }
    }
  }
}

struct MediaKeyPermissions: Equatable {
  var accessibility: Bool
  var inputMonitoring: Bool
  var musicAutomation: MusicAutomationPermissionStatus

  var mediaKeysGranted: Bool { accessibility && inputMonitoring }

  var allGranted: Bool {
    accessibility && inputMonitoring && musicAutomation == .granted
  }

  func isGranted(_ permission: MediaKeyPermission) -> Bool {
    switch permission {
    case .accessibility: return accessibility
    case .inputMonitoring: return inputMonitoring
    case .musicAutomation: return musicAutomation == .granted
    }
  }

  func statusLabel(for permission: MediaKeyPermission) -> String {
    switch permission {
    case .accessibility, .inputMonitoring:
      return isGranted(permission) ? "Allowed" : "Permission Needed"
    case .musicAutomation:
      switch musicAutomation {
      case .granted:
        return "Allowed"
      case .musicNotRunning:
        return "Music.app Not Running"
      case .notDetermined, .denied:
        return "Permission Needed"
      }
    }
  }

  func statusSymbol(for permission: MediaKeyPermission) -> String {
    switch permission {
    case .accessibility, .inputMonitoring:
      return isGranted(permission) ? "checkmark.circle.fill" : "exclamationmark.circle"
    case .musicAutomation:
      switch musicAutomation {
      case .granted:
        return "checkmark.circle.fill"
      case .musicNotRunning:
        return "music.note"
      case .notDetermined, .denied:
        return "exclamationmark.circle"
      }
    }
  }

  func actionTitle(for permission: MediaKeyPermission) -> String {
    switch permission {
    case .accessibility, .inputMonitoring:
      return "Open Settings"
    case .musicAutomation:
      switch musicAutomation {
      case .granted, .denied:
        return "Open Settings"
      case .notDetermined, .musicNotRunning:
        return "Allow Access"
      }
    }
  }

  static func current() -> Self {
    Self(
      accessibility: MediaKeyPermission.accessibility.isGranted,
      inputMonitoring: MediaKeyPermission.inputMonitoring.isGranted,
      musicAutomation: MusicPlayerController.shared.permissionStatus(askUserIfNeeded: false)
    )
  }
}
