import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics

/// UI names change in macOS 27; the underlying Accessibility API and pane anchor do not.
enum MediaKeyPermission: CaseIterable, Identifiable {
  case accessibility
  case inputMonitoring

  var id: Self { self }

  var title: String {
    switch self {
    case .accessibility:
      if #available(macOS 27, *) { return "Device Control and Data Access" }
      return "Accessibility"
    case .inputMonitoring:
      return "Input Monitoring"
    }
  }

  var explanation: String {
    switch self {
    case .accessibility:
      return
        "Lets Ambeo Companion intercept volume and mute keys and prevent macOS from handling them twice."
    case .inputMonitoring:
      return "Lets Ambeo Companion receive media keys while you use other apps."
    }
  }

  var isGranted: Bool {
    switch self {
    case .accessibility: return AXIsProcessTrusted()
    case .inputMonitoring: return CGPreflightListenEventAccess()
    }
  }

  @MainActor
  func requestAndOpenSettings() {
    if !isGranted {
      switch self {
      case .accessibility:
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
      case .inputMonitoring:
        _ = CGRequestListenEventAccess()
      }
    }
    let anchor = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ListenEvent"
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

  var allGranted: Bool { accessibility && inputMonitoring }

  func isGranted(_ permission: MediaKeyPermission) -> Bool {
    switch permission {
    case .accessibility: return accessibility
    case .inputMonitoring: return inputMonitoring
    }
  }

  static func current() -> Self {
    Self(
      accessibility: MediaKeyPermission.accessibility.isGranted,
      inputMonitoring: MediaKeyPermission.inputMonitoring.isGranted
    )
  }
}
