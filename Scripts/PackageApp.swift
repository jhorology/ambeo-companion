import Foundation

// configuration
let appName = "AmbeoCompanion"
let buildDir = ".build/release"
let appBundle = "\(appName).app"
let infoPlistSrc = "Sources/\(appName)/Info.plist"
let srcResources = "Sources/\(appName)/Resources"

let fm = FileManager.default

func shell(_ args: String...) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = args
  print("🛠  Running: \(args.joined(separator: " "))")
  try? process.run()
  process.waitUntilExit()
}

print("🚀 [1/4] Building Binary...")
shell("swift", "build", "-c", "release", "--product", appName)

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
// Resources
if let items = try? fm.contentsOfDirectory(atPath: srcResources) {
  for item in items {
    try! fm.copyItem(atPath: "\(srcResources)/\(item)", toPath: "\(resPath)/\(item)")
  }
}

print("✍️  [4/4] Signing App...")
shell("codesign", "--deep", "--force", "--options", "runtime", "--sign", "-", appBundle)

print("\n✅ Successfully created \(appBundle)!")
print("👉 Run with: open \(appBundle)")
