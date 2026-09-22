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
    openWindow(id: "settings-window")
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  var body: some Scene {
    MenuBarExtra("AMBEO Companion App", systemImage: "waveform.circle.fill") {
      VStack {
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
          NSApp.setActivationPolicy(.accessory)
        }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 450, height: 500)
  }
}
