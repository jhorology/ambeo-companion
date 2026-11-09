import AmbeoCore
import Foundation
import Logging
import Observation
import ServiceManagement

/// Manages `AppSettings` persistence in `UserDefaults` (with debounced writes) and Launch at Login
/// registration via `SMAppService`.
@Observable @MainActor final class AppSettingsStore {
  private let defaults: UserDefaults
  let storageKey: String
  private let debounceDelay: Duration
  private var saveTask: Task<Void, Never>?

  var launchAtLoginState: Bool = false

  init(
    defaults: UserDefaults = .standard,
    storageKey: String = "\(Bundle.id).Setting",
    debounceDelay: Duration = .milliseconds(500)
  ) {
    self.defaults = defaults
    self.storageKey = storageKey
    self.debounceDelay = debounceDelay
  }

  func load() -> AppSettings {
    if let data = defaults.data(forKey: storageKey),
      let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
    {
      return decoded
    }
    return AppSettings()
  }

  func debouncedSave(_ settings: AppSettings) {
    saveTask?.cancel()
    let delay = debounceDelay
    saveTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      self.saveNow(settings)
      Logger.lifecycle.debug("Debounced save executed.")
    }
  }

  func flushAndSaveNow(_ settings: AppSettings) {
    saveTask?.cancel()
    saveTask = nil
    saveNow(settings)
  }

  func saveNow(_ settings: AppSettings) {
    if let encoded = try? JSONEncoder().encode(settings) {
      defaults.set(encoded, forKey: storageKey)
    }
  }

  // MARK: - Launch at Login

  func checkLaunchAtLoginStatus() {
    if #available(macOS 13.0, *) { launchAtLoginState = (SMAppService.mainApp.status == .enabled) }
  }

  func setLaunchAtLogin(enabled: Bool) {
    if #available(macOS 13.0, *) {
      do {
        if enabled {
          if SMAppService.mainApp.status != .enabled {
            try SMAppService.mainApp.register()
            Logger.lifecycle.info("SMAppService: Registered mainApp for launch at login.")
          }
        } else {
          if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
            Logger.lifecycle.info("SMAppService: Unregistered mainApp from launch at login.")
          }
        }
        checkLaunchAtLoginStatus()
      } catch {
        Logger.lifecycle.warning(
          "SMAppService: Launch at Login update failed (\(error.localizedDescription))."
        )
        checkLaunchAtLoginStatus()
      }
    }
  }
}
