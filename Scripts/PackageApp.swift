import Foundation

// configuration
let appName = "AmbeoCompanion"
let buildDir = ".build/release"
let appBundle = "\(appName).app"
let infoPlistSrc = "Sources/\(appName)/Info.plist"
let srcResources = "Sources/\(appName)/Resources"

let fm = FileManager.default

@discardableResult
func shell(_ args: String...) -> Int32 {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = args
  print("🛠  Running: \(args.joined(separator: " "))")
  do {
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  } catch {
    print("❌ Failed to run command: \(error)")
    return 1
  }
}

print("🚀 [1/4] Building Binary...")
let buildStatus = shell("swift", "build", "-c", "release", "--product", appName)
if buildStatus != 0 {
  print("❌ Build failed with exit code \(buildStatus)")
  exit(buildStatus)
}

func safeCopy(from: String, to: String) {
  do {
    try fm.copyItem(atPath: from, toPath: to)
  } catch {
    print("❌ Failed to copy \(from) to \(to): \(error)")
    exit(1)
  }
}

func safeCreateDir(at: String) {
  do {
    try fm.createDirectory(atPath: at, withIntermediateDirectories: true)
  } catch {
    print("❌ Failed to create directory \(at): \(error)")
    exit(1)
  }
}

print("📦 [2/4] Creating Bundle Structure...")
let execPath = "\(appBundle)/Contents/MacOS"
let resPath = "\(appBundle)/Contents/Resources"

// clean appBundle & create folders
try? fm.removeItem(atPath: appBundle)
safeCreateDir(at: execPath)
safeCreateDir(at: resPath)

print("📂 [3/4] Copying Files...")
// executable file
safeCopy(from: "\(buildDir)/\(appName)", to: "\(execPath)/\(appName)")
// Info.plist
safeCopy(from: infoPlistSrc, to: "\(appBundle)/Contents/Info.plist")
// Resources (AppIcon.icns, etc.)
if let items = try? fm.contentsOfDirectory(atPath: srcResources) {
  for item in items {
    let dest = "\(resPath)/\(item)"
    try? fm.removeItem(atPath: dest)
    safeCopy(from: "\(srcResources)/\(item)", to: dest)
    print("  Copied resource: \(item)")
  }
}
// SPM Dependency Bundles (e.g. KeyboardShortcuts_KeyboardShortcuts.bundle)
if let buildItems = try? fm.contentsOfDirectory(atPath: buildDir) {
  for item in buildItems where item.hasSuffix(".bundle") {
    let dest = "\(resPath)/\(item)"
    try? fm.removeItem(atPath: dest)
    safeCopy(from: "\(buildDir)/\(item)", to: dest)
    print("  Copied package bundle: \(item)")
  }
}

print("✍️  [4/4] Signing App...")
// Sign inner bundles first
if let resItems = try? fm.contentsOfDirectory(atPath: resPath) {
  for item in resItems where item.hasSuffix(".bundle") {
    shell("codesign", "--force", "--options", "runtime", "--sign", "-", "\(resPath)/\(item)")
  }
}
// Sign the main app bundle
shell("codesign", "--force", "--options", "runtime", "--sign", "-", appBundle)

print("\n✅ Successfully created \(appBundle)!")
print("👉 Run with: open \(appBundle)")
