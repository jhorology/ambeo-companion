import Foundation
import Logging

@_silgen_name("swift_demangle")
public func _stdlib_demangle(
  mangledName: UnsafePointer<Int8>?,
  mangledNameLength: Int,
  outputBuffer: UnsafeMutablePointer<Int8>?,
  outputBufferLength: UnsafeMutablePointer<Int>?,
  flags: UInt32
) -> UnsafeMutablePointer<Int8>?

public struct SimpleFileLogConfig: Sendable {
  public let maxFileSize: UInt64
  public let maxBackupCount: Int
  public let isConsoleEnabled: Bool
  public let logLevel: Logger.Level
  public let isStackTraceEnabled: Bool

  public static let `default` = SimpleFileLogConfig(
    maxFileSize: 2 * 1024 * 1024,
    maxBackupCount: 5,
    isConsoleEnabled: true,
    logLevel: .trace,
    isStackTraceEnabled: true
  )
}

public struct SimpleFileLogHandler: LogHandler {
  public let label: String
  public var logLevel: Logger.Level
  public var metadata = Logger.Metadata()

  private let logFileURL: URL
  private let config: SimpleFileLogConfig

  public init(
    label: String,
    fileURL: URL,
    config: SimpleFileLogConfig = .default
  ) {
    self.label = label
    self.logFileURL = fileURL
    self.config = config
    self.logLevel = config.logLevel

    let dir = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(
      at: dir,
      withIntermediateDirectories: true
    )
  }

  public func log(
    level: Logger.Level,
    message: Logger.Message,
    metadata: Logger.Metadata?,
    source: String,
    file: String,
    function: String,
    line: UInt
  ) {
    let timestamp = formatDate(Date())
    let category = label.components(separatedBy: ".").last ?? label
    let fileName = (file as NSString).lastPathComponent

    let threadID = UnsafeMutableRawPointer(
      bitPattern: Int(pthread_mach_thread_np(pthread_self()))
    )!
    let threadName = Thread.isMainThread ? "main" : "thread-\(threadID)"

    let allMetadata = self.metadata.merging(metadata ?? [:]) { (_, new) in new }
    let metaString =
      allMetadata.isEmpty
      ? ""
      : " 🏷️ [\(allMetadata.map { "\($0.key): \($0.value)" }.joined(separator: ", "))]"

    var stackString = ""
    if config.isStackTraceEnabled && level >= .error {
      let symbols = Thread.callStackSymbols
        .dropFirst(5)
        .prefix(10)
        .map { demangle(symbol: $0) }
      stackString =
        "\n   📌 Stack Trace:\n   " + symbols.joined(separator: "\n   ")
    }

    let color = getColor(level)
    let reset = "\u{001B}[0m"

    let logLine =
      "\(timestamp) \(getEmoji(level)) \(color)[\(level.rawValue.uppercased())]\(reset) [\(threadName)] [\(category)] \(fileName):\(line) \(function) ➔ \(message)\(metaString)\(stackString)\n"

    if config.isConsoleEnabled {
      print(logLine, terminator: "")
    }
    writeWithRotation(logLine)
  }

  private func demangle(symbol: String) -> String {
    let parts = symbol.components(separatedBy: " ")
    guard let mangled = parts.first(where: { $0.hasPrefix("$s") }) else {
      return symbol
    }
    let ptr = _stdlib_demangle(
      mangledName: mangled,
      mangledNameLength: mangled.utf8.count,
      outputBuffer: nil,
      outputBufferLength: nil,
      flags: 0
    )
    if let p = ptr {
      let name = String(cString: p)
      free(p)
      return symbol.replacingOccurrences(of: mangled, with: name)
    }
    return symbol
  }

  private func writeWithRotation(_ line: String) {
    guard let data = line.data(using: .utf8) else { return }
    let fm = FileManager.default
    if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
      fileHandle.seekToEndOfFile()
      fileHandle.write(data)
      fileHandle.closeFile()
      if let attr = try? fm.attributesOfItem(atPath: logFileURL.path),
        (attr[.size] as? UInt64 ?? 0) > config.maxFileSize
      {
        rotateFiles(fm: fm)
      }
    } else {
      try? data.write(to: logFileURL)
    }
  }

  private func rotateFiles(fm: FileManager) {
    for i in (1...config.maxBackupCount).reversed() {
      let src =
        i == 1 ? logFileURL : logFileURL.appendingPathExtension("\(i-1)")
      let dst = logFileURL.appendingPathExtension("\(i)")
      if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
      if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: dst) }
    }
  }

  private func formatDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: date)
  }

  private func getEmoji(_ level: Logger.Level) -> String {
    let mapping: [Logger.Level: String] = [
      .trace: "🔍",
      .debug: "⚙️",
      .info: "💎",
      .notice: "🔔",
      .warning: "⚠️",
      .error: "🚫",
      .critical: "🔥",
    ]
    return mapping[level] ?? "📝"
  }

  private func getColor(_ level: Logger.Level) -> String {
    let colors: [Logger.Level: String] = [
      .trace: "\u{001B}[38;5;245m",
      .debug: "\u{001B}[34m",
      .info: "\u{001B}[32m",
      .notice: "\u{001B}[36m",
      .warning: "\u{001B}[33m",
      .error: "\u{001B}[31m",
      .critical: "\u{001B}[41;37m",
    ]
    return colors[level] ?? ""
  }

  public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }
}
