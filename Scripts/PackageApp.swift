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

print("📦 [2/4] Creating Bundle Structure...")
let execPath = "\(appBundle)/Contents/MacOS"
let resPath = "\(appBundle)/Contents/Resources"

// clean appBundle & create folders
try? fm.removeItem(atPath: appBundle)
try! fm.createDirectory(atPath: execPath, withIntermediateDirectories: true)
try! fm.createDirectory(atPath: resPath, withIntermediateDirectories: true)

print("📂 [3/4] Copying Files...")
// executable file
try! fm.copyItem(atPath: "\(buildDir)/\(appName)", toPath: "\(execPath)/\(appName)")
// Info.plist
try! fm.copyItem(atPath: infoPlistSrc, toPath: "\(appBundle)/Contents/Info.plist")
// Resources (AppIcon.icns, etc.)
if let items = try? fm.contentsOfDirectory(atPath: srcResources) {
  for item in items {
    let dest = "\(resPath)/\(item)"
    try? fm.removeItem(atPath: dest)
    try! fm.copyItem(atPath: "\(srcResources)/\(item)", toPath: dest)
    print("  Copied resource: \(item)")
  }
}
// SPM Dependency Bundles (e.g. KeyboardShortcuts_KeyboardShortcuts.bundle)
if let buildItems = try? fm.contentsOfDirectory(atPath: buildDir) {
  for item in buildItems where item.hasSuffix(".bundle") {
    let dest = "\(resPath)/\(item)"
    try? fm.removeItem(atPath: dest)
    try! fm.copyItem(atPath: "\(buildDir)/\(item)", toPath: dest)
    print("  Copied package bundle: \(item)")
  }
}

print("✍️  [4/4] Signing App...")
shell("codesign", "--deep", "--force", "--options", "runtime", "--sign", "-", appBundle)

print("\n✅ Successfully created \(appBundle)!")
print("👉 Run with: open \(appBundle)")
