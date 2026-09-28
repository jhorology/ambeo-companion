import AmbeoCore
import Logging
import SwiftUI

struct AmbeoCompanionApp: App {
  @State private var appModel = AppModel()
  @State private var didOfferDeviceSetup = false
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openURL) private var openURL

  private func openSettingsWindow() {
    NSApp.setActivationPolicy(.regular)
    NSApp.unhide(nil)
    openWindow(id: "settings-window")
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func revertToAccessory() {
    NSApp.hide(nil)
    let success = NSApp.setActivationPolicy(.accessory)
    Logger.lifecycle.debug("Reverted activation policy to .accessory: \(success)")
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

          Section("AMBEO Level (\(state.preset.capitalized))") {
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
          notif in
          guard let win = notif.object as? NSWindow,
            win.identifier?.rawValue == "settings-window" || win.title == "Settings"
          else {
            return
          }
          revertToAccessory()
        }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 450, height: 500)
  }
}
