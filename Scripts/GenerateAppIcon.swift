import AppKit
import CoreGraphics
import Foundation

// Generate 1024x1024 macOS App Icon for AmbeoCompanion
let size: CGFloat = 1024
let bounds = NSRect(x: 0, y: 0, width: size, height: size)

let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil,
  pixelsWide: Int(size),
  pixelsHigh: Int(size),
  bitsPerSample: 8,
  samplesPerPixel: 4,
  hasAlpha: true,
  isPlanar: false,
  colorSpaceName: .deviceRGB,
  bytesPerRow: 0,
  bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
let cg = context.cgContext

// Clear background
cg.clear(bounds)

// 1. Apple Standard Squircle Dimensions
let iconPadding: CGFloat = 100
let iconSize: CGFloat = size - (iconPadding * 2)  // 824x824
let iconRect = NSRect(x: iconPadding, y: iconPadding, width: iconSize, height: iconSize)
let cornerRadius: CGFloat = 185

let squirclePath = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)

// 2. Drop Shadow for the Outer Squircle
cg.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(deviceWhite: 0.0, alpha: 0.42)
shadow.shadowOffset = NSSize(width: 0, height: -22)
shadow.shadowBlurRadius = 36
shadow.set()

NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.15, alpha: 1.0).setFill()
squirclePath.fill()
cg.restoreGState()

// 3. Draw Outer Squircle Body
cg.saveGState()
squirclePath.addClip()

// Dark Slate / Navy Gradient
let outerColors =
  [
    NSColor(calibratedRed: 0.18, green: 0.23, blue: 0.29, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.22, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.13, alpha: 1.0).cgColor,
  ] as CFArray
let outerLocations: [CGFloat] = [0.0, 0.45, 1.0]
if let outerGrad = CGGradient(
  colorsSpace: CGColorSpaceCreateDeviceRGB(),
  colors: outerColors,
  locations: outerLocations
) {
  cg.drawLinearGradient(
    outerGrad,
    start: CGPoint(x: size / 2, y: size - iconPadding),
    end: CGPoint(x: size / 2, y: iconPadding),
    options: []
  )
}

// 4. Inner Silver Plate
let innerInset: CGFloat = 76
let innerSize = iconSize - (innerInset * 2)  // 672x672
let innerRect = NSRect(
  x: iconPadding + innerInset,
  y: iconPadding + innerInset,
  width: innerSize,
  height: innerSize
)
let innerCornerRadius: CGFloat = 140
let innerPlatePath = NSBezierPath(
  roundedRect: innerRect,
  xRadius: innerCornerRadius,
  yRadius: innerCornerRadius
)

// Subtle recessed shadow behind inner plate (top inset shadow)
cg.saveGState()
let innerShadow = NSShadow()
innerShadow.shadowColor = NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.07, alpha: 0.50)
innerShadow.shadowOffset = NSSize(width: 0, height: -5)
innerShadow.shadowBlurRadius = 10
innerShadow.set()
NSColor(calibratedRed: 0.9, green: 0.9, blue: 0.9, alpha: 1.0).setFill()
innerPlatePath.fill()
cg.restoreGState()

// Draw Inner Plate Surface Gradient
cg.saveGState()
innerPlatePath.addClip()

let plateColors =
  [
    NSColor(calibratedRed: 0.98, green: 0.99, blue: 1.0, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.95, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.84, green: 0.86, blue: 0.88, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.76, green: 0.78, blue: 0.81, alpha: 1.0).cgColor,
  ] as CFArray
let plateLocations: [CGFloat] = [0.0, 0.28, 0.72, 1.0]
if let plateGrad = CGGradient(
  colorsSpace: CGColorSpaceCreateDeviceRGB(),
  colors: plateColors,
  locations: plateLocations
) {
  cg.drawLinearGradient(
    plateGrad,
    start: CGPoint(x: size / 2, y: innerRect.maxY),
    end: CGPoint(x: size / 2, y: innerRect.minY),
    options: []
  )
}

// Subtle top inset ambient shadow on inner plate
let topInsetShadow = CGMutablePath()
topInsetShadow.addRect(
  CGRect(x: innerRect.minX, y: innerRect.maxY - 12, width: innerSize, height: 12)
)
cg.saveGState()
cg.setFillColor(NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.12, alpha: 0.08).cgColor)
cg.addPath(topInsetShadow)
cg.fillPath()
cg.restoreGState()

// Inner Plate subtle perimeter stroke (rim highlight / bevel)
cg.saveGState()
cg.setLineWidth(1.5)
cg.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.40).cgColor)
innerPlatePath.stroke()
cg.restoreGState()

// 5. Sennheiser AMBEO Logo
// Build the combined symbol path
let symbolPath = NSBezierPath()

// A. Top Bar
let barWidth: CGFloat = 596
let barHeight: CGFloat = 40
let topBarY: CGFloat = 718
let topBarRect = NSRect(
  x: 512 - barWidth / 2,
  y: topBarY - barHeight / 2,
  width: barWidth,
  height: barHeight
)
symbolPath.append(
  NSBezierPath(
    roundedRect: topBarRect,
    xRadius: barHeight / 2,
    yRadius: barHeight / 2
  )
)

// B. Bottom Bar
let bottomBarY: CGFloat = 306
let bottomBarRect = NSRect(
  x: 512 - barWidth / 2,
  y: bottomBarY - barHeight / 2,
  width: barWidth,
  height: barHeight
)
symbolPath.append(
  NSBezierPath(
    roundedRect: bottomBarRect,
    xRadius: barHeight / 2,
    yRadius: barHeight / 2
  )
)

// C. Center Horizontal Line
let centerLineWidth: CGFloat = 510
let centerLineHeight: CGFloat = 38
let centerLineRect = NSRect(
  x: 512 - centerLineWidth / 2,
  y: 512 - centerLineHeight / 2,
  width: centerLineWidth,
  height: centerLineHeight
)
symbolPath.append(
  NSBezierPath(
    roundedRect: centerLineRect,
    xRadius: centerLineHeight / 2,
    yRadius: centerLineHeight / 2
  )
)

// D. 7 Vertical Bars
let vBarWidth: CGFloat = 38
let pitch: CGFloat = 64
let vBarHeights: [CGFloat] = [124, 196, 144, 296, 260, 196, 124]

for i in 0..<7 {
  let cx = 512 + CGFloat(i - 3) * pitch
  let h = vBarHeights[i]
  let r = NSRect(x: cx - vBarWidth / 2, y: 512 - h / 2, width: vBarWidth, height: h)
  symbolPath.append(
    NSBezierPath(
      roundedRect: r,
      xRadius: vBarWidth / 2,
      yRadius: vBarWidth / 2
    )
  )
}

// Symbol subtle bottom highlight (emboss effect)
cg.saveGState()
let symHighlight = NSShadow()
symHighlight.shadowColor = NSColor(calibratedWhite: 1.0, alpha: 0.55)
symHighlight.shadowOffset = NSSize(width: 0, height: -1.5)
symHighlight.shadowBlurRadius = 1.0
symHighlight.set()

NSColor(calibratedWhite: 1.0, alpha: 0.3).setFill()
symbolPath.fill()
cg.restoreGState()

// Symbol drop shadow on the silver plate (subtle depth)
cg.saveGState()
let symShadow = NSShadow()
symShadow.shadowColor = NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.18, alpha: 0.25)
symShadow.shadowOffset = NSSize(width: 0, height: -2.0)
symShadow.shadowBlurRadius = 3.5
symShadow.set()

NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.24, alpha: 1.0).setFill()
symbolPath.fill()
cg.restoreGState()

// Symbol gradient fill
cg.saveGState()
symbolPath.addClip()

let symColors =
  [
    NSColor(calibratedRed: 0.20, green: 0.26, blue: 0.32, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.15, green: 0.20, blue: 0.26, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.17, alpha: 1.0).cgColor,
  ] as CFArray
let symLocations: [CGFloat] = [0.0, 0.45, 1.0]
if let symGrad = CGGradient(
  colorsSpace: CGColorSpaceCreateDeviceRGB(),
  colors: symColors,
  locations: symLocations
) {
  cg.drawLinearGradient(
    symGrad,
    start: CGPoint(x: 512, y: topBarRect.maxY),
    end: CGPoint(x: 512, y: bottomBarRect.minY),
    options: []
  )
}
cg.restoreGState()

// End Inner Plate Clip
cg.restoreGState()

// 6. Bevel highlight along top edge of Outer Squircle
let highlightPath = CGMutablePath()
highlightPath.addArc(
  center: CGPoint(x: iconPadding + cornerRadius, y: size - iconPadding - cornerRadius),
  radius: cornerRadius - 1.5,
  startAngle: .pi,
  endAngle: .pi * 0.5,
  clockwise: true
)
highlightPath.addLine(
  to: CGPoint(x: size - iconPadding - cornerRadius, y: size - iconPadding - 1.5)
)
highlightPath.addArc(
  center: CGPoint(x: size - iconPadding - cornerRadius, y: size - iconPadding - cornerRadius),
  radius: cornerRadius - 1.5,
  startAngle: .pi * 0.5,
  endAngle: 0,
  clockwise: true
)

cg.saveGState()
cg.setLineWidth(2.0)
cg.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.18).cgColor)
cg.addPath(highlightPath)
cg.strokePath()
cg.restoreGState()

// Outer rim stroke
cg.saveGState()
cg.setLineWidth(1.5)
cg.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.10).cgColor)
squirclePath.stroke()
cg.restoreGState()

// End Outer Squircle Clip
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()

// Save to 1024x1024 PNG
guard let pngData = rep.representation(using: .png, properties: [:]) else {
  fatalError("Failed to convert image to PNG")
}

let outputPath = "Sources/AmbeoCompanion/Resources/AppIcon_1024.png"
let outputURL = URL(fileURLWithPath: outputPath)
try! pngData.write(to: outputURL)
print("✅ Generated \(outputPath)")

// Generate .iconset and compile to .icns
let iconsetDir = "Sources/AmbeoCompanion/Resources/AppIcon.iconset"
let icnsPath = "Sources/AmbeoCompanion/Resources/AppIcon.icns"
let fm = FileManager.default

try? fm.removeItem(atPath: iconsetDir)
try! fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024),
]

for item in sizes {
  let targetPath = "\(iconsetDir)/\(item.name)"
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
  process.arguments = ["-z", "\(item.px)", "\(item.px)", outputPath, "--out", targetPath]
  try? process.run()
  process.waitUntilExit()
}

// Compile iconset to icns
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try? iconutil.run()
iconutil.waitUntilExit()

// Clean up temporary iconset directory
try? fm.removeItem(atPath: iconsetDir)

// Also update AmbeoCompanion.app bundle if present
let appResPath = "AmbeoCompanion.app/Contents/Resources"
if fm.fileExists(atPath: appResPath) {
  try? fm.removeItem(atPath: "\(appResPath)/AppIcon.icns")
  try? fm.removeItem(atPath: "\(appResPath)/AppIcon_1024.png")
  try? fm.copyItem(atPath: icnsPath, toPath: "\(appResPath)/AppIcon.icns")
  try? fm.copyItem(atPath: outputPath, toPath: "\(appResPath)/AppIcon_1024.png")
  print("✅ Updated \(appResPath)")
}

print("🎉 Successfully generated \(icnsPath)!")
