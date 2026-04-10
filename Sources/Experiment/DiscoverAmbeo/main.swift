import AmbeoCore
import Foundation
import Logging

LogManager.setup()

Task {
  Logger.lifecycle.debug("Discovering with main thread for 20 seconds...")
  let mainTask = Task {
    for await devices in SennheiserDiscovery.browse() {
      Logger.lifecycle.debug("Founded devices: \(devices)")
    }
  }
  try? await Task.sleep(for: .seconds(20))

  Logger.lifecycle.debug("Canceling a task on main thread")
  mainTask.cancel()

  Logger.lifecycle.debug("Discovering with detached thread for 20 seconds...")
  let otherTask = Task.detached {
    for await devices in SennheiserDiscovery.browse() {
      Logger.lifecycle.debug("Founded devices: \(devices)")
    }
  }
  try? await Task.sleep(for: .seconds(20))

  Logger.lifecycle.debug("Canceling a task on detached thread")
  otherTask.cancel()
  try? await Task.sleep(for: .seconds(2))
}
RunLoop.main.run()
