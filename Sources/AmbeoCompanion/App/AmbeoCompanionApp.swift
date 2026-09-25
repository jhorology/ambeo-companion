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
