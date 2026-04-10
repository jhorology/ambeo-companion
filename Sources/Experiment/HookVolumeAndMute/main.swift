import AmbeoCore
import AppKit
import Foundation
import Logging

@MainActor
class HookVolumeAndMute {
  var audioDeviceUid: String = "" {
    didSet {
      if oldValue != audioDeviceUid {
        if audioDeviceUid.isEmpty {
          monitorTask?.cancel()
          monitorTask = nil
        } else {
          startMonitoring()
        }
      }
    }
  }

  private var monitorTask: Task<Void, Never>? = nil

  init() {
    setupNotifications()
  }

  func startMonitoring() {
    monitorTask?.cancel()

    monitorTask = Task {
      let stream = SystemEventMonitor.events(shouldIntercept: { [audioDeviceUid] ev in
        guard ev.isDown, case .media(let key) = ev.type else { return false }
        let targetKeys: [SystemEvent.MediaKey] = [.soundUp, .soundDown, .mute]
        guard targetKeys.contains(key) else { return false }

        guard
          let device = AudioDeviceMonitor.shared.audioDevice(withUid: audioDeviceUid)
        else {
          Logger.audio.debug("Target device: [uid=\(audioDeviceUid)] not found.")
          return false
        }
        if let curDev = AudioDeviceMonitor.shared.currentDefaultDevice {
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

  func setupNotifications() {
    let nc = NSWorkspace.shared.notificationCenter

    let stopEvents = [
      NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
    ]
    for name in stopEvents {
      nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in
          self?.monitorTask?.cancel()
          self?.monitorTask = nil
          Logger.lifecycle.debug("Stopped monitoring via \(name.rawValue)")
        }
      }
    }

    let startEvents = [
      NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
    ]
    for name in startEvents {
      nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in
          if let uid = self?.audioDeviceUid, !uid.isEmpty {
            self?.startMonitoring()
            Logger.lifecycle.debug("Started monitoring via \(name.rawValue)")
          }
        }
      }
    }
  }
}

func audioDevice(startingWith prefix: String) -> AudioDevice? {
  guard
    let device = AudioDeviceMonitor.shared.allOutputDevices.first(where: {
      $0.name.hasPrefix(prefix)
    })
  else {
    Logger.lifecycle.error("Target device: [prefix=\(prefix)] not found.")
    return nil
  }
  Logger.lifecycle.debug("Target device: \(device).")
  return device
}

LogManager.setup()
Logger.lifecycle.debug("Start")

guard let babyface = audioDevice(startingWith: "Babyface Pro") else { exit(1) }
Logger.lifecycle.debug(
  "Currnt default auduio device is [\(String(describing:AudioDeviceMonitor.shared.currentDefaultDevice))]"
)

Task {
  let test = HookVolumeAndMute()
  test.setupNotifications()
  test.audioDeviceUid = babyface.uid

  try? await Task.sleep(for: .seconds(20))

  guard let ambeo = audioDevice(startingWith: "AW3225QF") else { exit(1) }
  Logger.lifecycle.debug(
    "Taget device is Hogged: \(String(describing:AudioDeviceMonitor.shared.checkHogged(for: ambeo.id)))"
  )
  test.audioDeviceUid = ambeo.uid
}
RunLoop.main.run()
