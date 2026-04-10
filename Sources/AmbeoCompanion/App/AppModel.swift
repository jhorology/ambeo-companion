import AmbeoCore
import Foundation
import Logging
import SwiftUI

struct AppSettings: Codable {
  var ambeoUid: String = ""
  var audioDeviceUid: String = ""
  var fallbackAudioFormat: AudioPhysicalFormat? = nil
  var mediaKeyEnabled: Bool = true
  var atmosBoostAmount: Double = 0
}

@Observable
@MainActor
final class AppModel: Sendable {
  private let storageKey = "\(Bundle.id).Setting"
  private let hookedKeys: [SystemEvent.MediaKey] = [.soundUp, .soundDown, .mute]

  private var saveTask: Task<Void, Never>?
  private var discoveringAmbeoTask: Task<Void, Never>?
  private var monitoringAudioDeviceTask: Task<Void, Never>?
  private var monitoringSystemEventTask: Task<Void, Never>?

  var settings: AppSettings {
    didSet {
      debouncedSaveSettings()
    }
  }

  private(set) var networkDevices: [SennheiserNetworkDevice] = []

  var currntAudioDvice: AudioDevice? = nil

  init() {
    loadSettings()
    startDiscoveringAmbeo()
    startMonitoringAudioDevice()

    setupNotifications()
  }

  private func startDiscoveringAmbeo() {
    discoveringAmbeoTask?.cancel()

    discoveringAmbeoTask = Task {
      for await devices in SennheiserDiscovery.browse() {
        self.networkDevices = devices
        Logger.network.debug("Discovered devices updated: \(devices.count) devices")
      }
    }
  }

  private func startMonitoringAudioDevice() {
    monitoringAudioDeviceTask?.cancel()

    monitoringAudioDeviceTask = Task {
      for await device in AudioDeviceMonitor.shared.defaultDeviceStream {
        Logger.audio.debug("Default audio device changed: \(String(describing:device))")
        if let curDev = device,
           let format = settings.fallbackAudioFormat,
           curDev.uid == self.settings.ambeoUid
        {
          AudioDeviceMonitor.shared.fallback(format: format, for: curDev.id)
        }
      }
    }
  }

  func startMonitoringSystemEvent() {
    monitoringSystemEventTask?.cancel()

    monitoringSystemEventTask = Task {
      let stream = SystemEventMonitor.events(shouldIntercept: { [weak self] ev in
        // filter event
        guard ev.isDown,
          case .media(let key) = ev.type,
          self?.hookedKeys.contains(key) == true
        else { return false }

        guard
          let uid = self?.settings.ambeoUid,
          let device = AudioDeviceMonitor.shared.audioDevice(withUid: uid)
        else {
          Logger.audio.debug(
            "Target device: [uid=\(String(describing:self?.settings.ambeoUid))] not found."
          )
          return false
        }
        if let curDev = AudioDeviceMonitor.shared.currentDefaultDevice,
           curDev.uid == audioDeviceUid {
           {
          Logger.audio.debug("Currnt default device: [\(String(describing:curDev))].")
          if curDev.uid == audioDeviceUid {
            return true
          } else {
            Logger.audio.debug("Target device: [uid=\(audioDeviceUid)] is not default device.")
          }
        }
        if AudioDeviceMonitor.shared.checkHogged(for: device.id) {
          Logger.audio.debug("Target deviice: [uid=\(audioDeviceUid)] is hogged.")
          return true
        }
        return false
      })

      for await event in stream {
        Logger.lifecycle.debug("Event notified in stream: \(String(describing: event.type))")
      }
    }
  }

  private func setupNotifications() {
    let nc = NSWorkspace.shared.notificationCenter

    // wake from sleep
    nc.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { _ in
      startDiscoveringAmbeo()
      startMonitoringAudioDevice()

      Logger.lifecycle.info("Wake from sleep")
    }

    // will sleep
    nc.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { _ in

      monitoringAudioDeviceTask?.cancel()
      discoveringAmbeoTask?.cancel()

      Logger.lifecycle.info("Will sleep")
    }

    // screen did lock
    // nc.addObserver(forName: NSWorkspace.screensDidLockNotification, object: nil, queue: .main) {
    //   _ in
    //   Logger.lifecycle.info("Screen did lock")
    // }

    // screen did unlock
    // nc.addObserver(forName: NSWorkspace.screensDidUnlockNotification, object: nil, queue: .main) {
    //   _ in
    //   Logger.lifecycle.info("Screen did Unlock")
    // }

    // screensaver did zstart, display may be turned off
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("com.apple.screensaver.didstart"),
      object: nil,
      queue: .main
    ) { _ in
      // TODO
      Logger.lifecycle.info("Screensaver did start")
    }

  }

  private func loadSettings() {
    if let data = UserDefaults.standard.data(forKey: storageKey),
      let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
    {
      settings = decoded
    } else {
      settings = AppSettings()
    }
  }

  private func debouncedSaveSettings(_: timeMs = 500) {
    saveTask?.cancel()
    saveTask = Task {
      try? await Task.sleep(for: .milliseconds(500))

      if !Task.isCancelled {
        saveSettings()
        Logger.lifecycle.debug("Debounced save executed.")
      }
    }
  }

  private func saveSettings() {
    if let encoded = try? JSONEncoder().encode(settings) {
      UserDefaults.standard.set(encoded, forKey: storageKey)
    }
  }
}
