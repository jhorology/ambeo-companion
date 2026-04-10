import AmbeoCore
import Logging
import SwiftUI

struct AmbeoCompanionApp: App {
  @State private var appModel = AppModel()
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openURL) private var openURL
  @AppStorage("AmbeoNetDeviceUID") private var savedDeviceUID: String = ""

  private func openSettingsWindow() {
    // .accessory to .regular
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
          if let device = appModel.discoveredDevices.first(where: { $0.id == savedDeviceUID }),
            let url = URL(string: "http://\(device.ip)")
          {
            openURL(url)
          }
        }.disabled(
          savedDeviceUID.isEmpty
            || !appModel.discoveredDevices.contains(where: { $0.id == savedDeviceUID })
        )
        Button("Settings...", systemImage: "gearshape") {
          openSettingsWindow()
        }
        .keyboardShortcut(",", modifiers: .command)  // Macの標準ショートカット Command + ,

        Divider()

        Button("Quit Ambeo Companion", systemImage: "xmark.rectangle") {
          NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
      }
    }
    .menuBarExtraStyle(.menu)
    .onChange(of: appModel.discoveredDevices) { (_, _) in
      if savedDeviceUID.isEmpty {
        openSettingsWindow()
      }
    }

    Window("Settings", id: "settings-window") {
      SettingsView()
        .environment(appModel)
        .onDisappear {
          // revert to .accessory
          NSApp.setActivationPolicy(.accessory)
        }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 450, height: 500)
  }
}
