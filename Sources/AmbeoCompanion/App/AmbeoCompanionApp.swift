import AmbeoCore
import Logging
import SwiftUI

struct AmbeoCompanionApp: App {
  @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) private var delegate
  @State private var appModel = AppModel()
  @State private var didOfferDeviceSetup = false
  @State private var didOfferPermissionSetup = false
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openURL) private var openURL

  private func openPermissionWindow() {
    NSApp.setActivationPolicy(.regular)
    NSApp.unhide(nil)
    openWindow(id: "permissions-window")
    DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
  }

  private func openSettingsWindow() {
    NSApp.setActivationPolicy(.regular)
    NSApp.unhide(nil)
    openWindow(id: "settings-window")
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private static let managedWindowIDs = ["settings-window", "permissions-window"]

  private static func isManagedWindow(_ window: NSWindow) -> Bool {
    if window.title == "Settings" || window.title == "Permissions" { return true }
    guard let id = window.identifier?.rawValue else { return false }
    return managedWindowIDs.contains(where: { id.hasPrefix($0) })
  }

  /// Returns to `.accessory` (no Dock icon / Cmd+Tab entry) once no managed window remains.
  /// While `willClose` / `onDisappear` fire, the closing window still reports `isVisible == true`,
  /// so the closing window is excluded and the check is deferred to the next run loop turn.
  private func revertToAccessory(closing: NSWindow? = nil) {
    DispatchQueue.main.async {
      guard
        !NSApp.windows.contains(where: {
          $0 !== closing && $0.isVisible && Self.isManagedWindow($0)
        })
      else { return }
      guard NSApp.activationPolicy() != .accessory else { return }
      NSApp.hide(nil)
      let success = NSApp.setActivationPolicy(.accessory)
      Logger.lifecycle.debug("Reverted activation policy to .accessory: \(success)")
    }
  }

  private var windowWillClose: NotificationCenter.Publisher {
    NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
  }

  private func handleWillClose(_ notif: Notification) {
    guard let win = notif.object as? NSWindow, Self.isManagedWindow(win) else { return }
    revertToAccessory(closing: win)
  }

  private static func presetIcon(_ preset: String) -> String {
    switch preset {
    case "adaptive": return "wand.and.stars"
    case "music": return "music.note"
    case "movie": return "film"
    case "news": return "newspaper"
    case "sports": return "sportscourt"
    default: return "slider.horizontal.3"  // neutral
    }
  }

  private static func ambeoLevelIcon(_ level: String) -> String {
    switch level {
    case "light": return "speaker.wave.1"
    case "boost": return "speaker.wave.3"
    default: return "speaker.wave.2"  // standard
    }
  }

  var body: some Scene {
    MenuBarExtra("AMBEO Companion App", systemImage: "waveform.circle.fill") {
      VStack {
        if let state = appModel.soundbarState {
          Section("Preset") {
            Picker(
              "Preset",
              selection: Binding(
                get: { state.preset.lowercased() },
                set: { preset in Task { await appModel.setPreset(preset) } }
              )
            ) {
              ForEach(AmbeoEndpoint.Audio.Preset.allPresets, id: \.self) { preset in
                Label(preset.capitalized, systemImage: Self.presetIcon(preset)).tag(preset)
              }
            }
            .pickerStyle(.inline)
            .labelsHidden()
          }

          Section("AMBEO (\(state.preset.capitalized))") {
            Toggle(
              isOn: Binding(
                get: { state.isAmbeoMode },
                set: { _ in Task { await appModel.toggleAmbeoMode() } }
              )
            ) {
              Label("AMBEO Mode", systemImage: "waveform")
            }

            Picker(
              "AMBEO Level",
              selection: Binding(
                get: { state.ambeoLevel.lowercased() },
                set: { level in Task { await appModel.setAmbeoLevel(level) } }
              )
            ) {
              ForEach(AmbeoEndpoint.Audio.AmbeoLevel.allLevels, id: \.self) { level in
                Label(level.capitalized, systemImage: Self.ambeoLevelIcon(level)).tag(level)
              }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(!state.isAmbeoMode)
          }

          Section {
            Toggle(
              isOn: Binding(
                get: { state.isNightMode },
                set: { _ in Task { await appModel.toggleNightMode() } }
              )
            ) {
              Label("Night Mode", systemImage: "moon.fill")
            }

            Toggle(
              isOn: Binding(
                get: { state.isVoiceEnhancement },
                set: { _ in Task { await appModel.toggleVoiceEnhancement() } }
              )
            ) {
              Label("Voice Enhancement", systemImage: "waveform.and.person.filled")
            }
          }

          Divider()
        }

        Button("Smart Control...", systemImage: "network") {
          if let device = appModel.networkDevices.first(where: {
            $0.uuid == appModel.settings.ambeoUid
          }),
            let url = URL(string: "http://\(device.ip)")
          {
            openURL(url)
          }
        }
        .disabled(
          appModel.settings.ambeoUid.isEmpty
            || !appModel.networkDevices.contains(where: { $0.uuid == appModel.settings.ambeoUid })
        )

        Button("Wake Up Soundbar", systemImage: "bolt.fill") {
          Task { await appModel.wakeUpSoundbar() }
        }
        .disabled(appModel.ambeoClient == nil)

        Button("Permissions...", systemImage: "lock.shield") {
          openPermissionWindow()
        }

        Button("Settings...", systemImage: "gearshape") {
          openSettingsWindow()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Ambeo Companion", systemImage: "xmark.rectangle") {
          NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
      }
    }
    .menuBarExtraStyle(.menu)
    // Offer once per launch. The Music.app Automation status flips with Music.app launching and
    // quitting, so re-arming on every change would reopen the window each time Music.app starts.
    .onChange(of: appModel.needsPermissionOnboarding, initial: true) { _, needed in
      guard needed, !didOfferPermissionSetup else { return }
      didOfferPermissionSetup = true
      openPermissionWindow()
    }
    .onChange(of: appModel.networkDevices) { _, devices in
      guard appModel.settings.ambeoUid.isEmpty, !devices.isEmpty, !didOfferDeviceSetup else {
        return
      }
      didOfferDeviceSetup = true
      openSettingsWindow()
    }

    Window("Settings", id: "settings-window") {
      SettingsView()
        .environment(appModel)
        .onDisappear {
          revertToAccessory()
        }
        .onReceive(windowWillClose, perform: handleWillClose)
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 450, height: 500)

    Window("Permissions", id: "permissions-window") {
      PermissionOnboardingView()
        .environment(appModel)
        .onDisappear { revertToAccessory() }
        .onReceive(windowWillClose, perform: handleWillClose)
    }
    .windowResizability(.contentSize)
  }
}

@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
  private var isTerminating = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model = AppModel.runningInstance else { return .terminateNow }
    guard !isTerminating else { return .terminateLater }
    isTerminating = true
    Task {
      await model.prepareForTermination()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
