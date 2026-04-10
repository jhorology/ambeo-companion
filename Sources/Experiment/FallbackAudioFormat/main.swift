//
// While playing a Dolny Atmos song on Apple Music, quit with Command + Q
// and check that the format returns to 2ch 48Khz 24bit in Audio MIDI Setup.app.
//
import AmbeoCore
import Foundation
import Logging

LogManager.setup()

Logger.lifecycle.debug("Start")

let deviceName = "AW3225QF"
guard
  let ambeo = AudioDeviceMonitor.shared.allOutputDevices.first(where: {
    $0.name == deviceName
  })
else {
  Logger.lifecycle.error("Device: [name=\(deviceName)] not found")
  exit(1)
}

let formats = AudioDeviceMonitor.shared.supportedFormats(for: ambeo.id)
// 2ch 48Khz 24bit
guard
  let format =
    formats
    .filter({ $0.channels == 2 })
    .sorted(by: { a, b in
      if a.sampleRate != b.sampleRate {
        return a.distanceFrom48kHz < b.distanceFrom48kHz
      }
      return a.bitDepth > b.bitDepth
    }).first
else {
  Logger.lifecycle.error("No valid format found.")
  exit(1)
}

let mainTask = Task {
  for await device in AudioDeviceMonitor.shared.defaultDeviceStream {
    guard let dev = device else { return }
    if ambeo.uid == dev.uid {
      AudioDeviceMonitor.shared.fallback(format: format, for: dev.id)
    }
    Logger.lifecycle.debug("Current device: \(dev)")
  }
}
RunLoop.main.run()
