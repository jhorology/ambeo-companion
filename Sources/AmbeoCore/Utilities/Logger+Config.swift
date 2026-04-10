import Foundation
import Logging

extension Logger {
  private static let subsystem = "io.github.jhorology.ambeo-companion"
  public static let network = Logger(label: "\(subsystem).Network")
  public static let audio = Logger(label: "\(subsystem).CoreAudio")
  public static let ui = Logger(label: "\(subsystem).UI")
  public static let lifecycle = Logger(label: "\(subsystem).Lifecycle")
}

public enum LogManager {
  private static func logFileURL(_ bundleId: String?) -> URL {
    #if DEBUG
    // <Project>/Logs/amebeo-companion.log
    URL(fileURLWithPath: #filePath)  // <project>/Sources/AmbeoCore/Utilities/<this file>
      .deletingLastPathComponent()  // <project>/Sources/AmbeoCore/Utilities
      .deletingLastPathComponent()  // <project>/Sources/AmbeoCore
      .deletingLastPathComponent()  // <project>/Sources
      .deletingLastPathComponent()  // <project>
      .appendingPathComponent("Logs")
      .appendingPathComponent("ambeo-companion.log")
    #else
    // ~/Library/Logs/<Bundle ID>/amebeo-companion.log
    try! fileManager.default.url(
      for: .libraryDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    .appendingPathComponent("Logs")
    .appendingPathComponent(bundleId!)
    .appendingPathComponent("amebeo-companion.log")
    #endif
  }

  private static let config: SimpleFileLogConfig = {
    #if DEBUG
    .init(
      maxFileSize: 2 * 1024 * 1024,
      maxBackupCount: 2,
      isConsoleEnabled: true,
      logLevel: .trace,
      isStackTraceEnabled: true
    )
    #else
    .init(
      maxFileSize: 2 * 1024 * 1024,
      maxBackupCount: 5,
      isConsoleEnabled: false,
      logLevel: .info,
      isStackTraceEnabled: false
    )
    #endif
  }()

  public static func setup(bid bundleId: String = "io.github.jhorology.ambeo-companion.dev") {
    let url = logFileURL(bundleId)
    LoggingSystem.bootstrap {
      SimpleFileLogHandler(label: $0, fileURL: url, config: config)
    }
    Logger.lifecycle.info("Logger initialized  with Bundle ID:\(bundleId)")
  }
}
