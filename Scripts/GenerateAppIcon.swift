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

// 2. Drop Shadow for the Squircle
cg.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowOffset = NSSize(width: 0, height: -22)
shadow.shadowBlurRadius = 38
shadow.set()

// Draw shadow base
NSColor(deviceWhite: 0.1, alpha: 1.0).setFill()
squirclePath.fill()
cg.restoreGState()

// 3. Squircle Background & Clip
cg.saveGState()
squirclePath.addClip()

// Dark Titanium / Obsidian Gradient
let bgColors =
  [
    NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.18, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.06, alpha: 1.0).cgColor,
  ] as CFArray
let bgLocations: [CGFloat] = [0.0, 0.6, 1.0]
if let bgGradient = CGGradient(
  colorsSpace: CGColorSpaceCreateDeviceRGB(),
  colors: bgColors,
  locations: bgLocations
) {
  cg.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: size / 2, y: size - iconPadding),
    end: CGPoint(x: size / 2, y: iconPadding),
    options: []
  )
}

// Subtle Radial Ambient Glow behind the waves
let glowColors =
  [
    NSColor(calibratedRed: 0.0, green: 0.8, blue: 1.0, alpha: 0.28).cgColor,
    NSColor(calibratedRed: 0.7, green: 0.2, blue: 1.0, alpha: 0.16).cgColor,
    NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.0).cgColor,
  ] as CFArray
let glowLocations: [CGFloat] = [0.0, 0.55, 1.0]
if let glowGrad = CGGradient(
  colorsSpace: CGColorSpaceCreateDeviceRGB(),
  colors: glowColors,
  locations: glowLocations
) {
  cg.drawRadialGradient(
    glowGrad,
    startCenter: CGPoint(x: size / 2, y: 460),
    startRadius: 0,
    endCenter: CGPoint(x: size / 2, y: 460),
    endRadius: 420,
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
  )
}

// 4. Subtle Acoustic Spherical Grid Lines in Background
cg.saveGState()
cg.setLineWidth(1.2)
cg.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.05).cgColor)
for r: CGFloat in stride(from: 120, through: 420, by: 45) {
  cg.addArc(
    center: CGPoint(x: size / 2, y: 320),
    radius: r,
    startAngle: 0,
    endAngle: .pi,
    clockwise: false
  )
  cg.strokePath()
}
cg.restoreGState()

// 5. 3D Spatial Audio Concentric Waves (The AMBEO Sound Experience)
let waveCenter = CGPoint(x: size / 2, y: 330)

struct WaveDef {
  let radius: CGFloat
  let startAngle: CGFloat
  let endAngle: CGFloat
  let lineWidth: CGFloat
  let colorStart: NSColor
  let colorEnd: NSColor
  let glowColor: NSColor
}

let waves: [WaveDef] = [
  // Outer spatial immersion wave (Electric Blue to Cyan)
  WaveDef(
    radius: 320,
    startAngle: .pi * 0.20,
    endAngle: .pi * 0.80,
    lineWidth: 18,
    colorStart: NSColor(calibratedRed: 0.1, green: 0.6, blue: 1.0, alpha: 0.9),
    colorEnd: NSColor(calibratedRed: 0.0, green: 0.95, blue: 1.0, alpha: 0.95),
    glowColor: NSColor(calibratedRed: 0.0, green: 0.8, blue: 1.0, alpha: 0.5)
  ),
  // Mid-outer surround wave (Vibrant AMBEO Purple - signature Night Mode & Sennheiser aesthetic)
  WaveDef(
    radius: 245,
    startAngle: .pi * 0.16,
    endAngle: .pi * 0.84,
    lineWidth: 22,
    colorStart: NSColor(calibratedRed: 0.85, green: 0.3, blue: 1.0, alpha: 1.0),
    colorEnd: NSColor(calibratedRed: 0.6, green: 0.15, blue: 1.0, alpha: 1.0),
    glowColor: NSColor(calibratedRed: 0.85, green: 0.3, blue: 1.0, alpha: 0.7)
  ),
  // Mid wave (Cyan to Magenta transition)
  WaveDef(
    radius: 175,
    startAngle: .pi * 0.12,
    endAngle: .pi * 0.88,
    lineWidth: 24,
    colorStart: NSColor(calibratedRed: 0.0, green: 0.95, blue: 1.0, alpha: 1.0),
    colorEnd: NSColor(calibratedRed: 0.8, green: 0.25, blue: 1.0, alpha: 1.0),
    glowColor: NSColor(calibratedRed: 0.0, green: 0.9, blue: 1.0, alpha: 0.8)
  ),
  // Inner core wave (Brilliant Neon Cyan - signature AMBEO illuminated LED)
  WaveDef(
    radius: 105,
    startAngle: .pi * 0.08,
    endAngle: .pi * 0.92,
    lineWidth: 26,
    colorStart: NSColor(calibratedRed: 0.2, green: 1.0, blue: 1.0, alpha: 1.0),
    colorEnd: NSColor(calibratedRed: 0.0, green: 0.8, blue: 1.0, alpha: 1.0),
    glowColor: NSColor(calibratedRed: 0.0, green: 1.0, blue: 1.0, alpha: 0.9)
  ),
]

for wave in waves {
  cg.saveGState()

  // Outer Bloom / Glow
  cg.setShadow(
    offset: CGSize(width: 0, height: 0),
    blur: 26,
    color: wave.glowColor.cgColor
  )

  // Wave path
  let path = CGMutablePath()
  path.addArc(
    center: waveCenter,
    radius: wave.radius,
    startAngle: wave.startAngle,
    endAngle: wave.endAngle,
    clockwise: false
  )

  cg.setLineWidth(wave.lineWidth)
  cg.setLineCap(.round)

  // Stroke wave with gradient
  let strokedPath = path.copy(
    strokingWithWidth: wave.lineWidth,
    lineCap: .round,
    lineJoin: .round,
    miterLimit: 10
  )
  cg.addPath(strokedPath)
  cg.clip()

  let wColors = [wave.colorStart.cgColor, wave.colorEnd.cgColor] as CFArray
  if let wGrad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: wColors,
    locations: [0.0, 1.0]
  ) {
    cg.drawLinearGradient(
      wGrad,
      start: CGPoint(x: waveCenter.x - wave.radius, y: waveCenter.y),
      end: CGPoint(x: waveCenter.x + wave.radius, y: waveCenter.y + wave.radius * 0.8),
      options: []
    )
  }

  cg.restoreGState()
}

// 6. Soundbar Silhouette at Bottom of Motif
let barWidth: CGFloat = 500
let barHeight: CGFloat = 58
let barX = (size - barWidth) / 2
let barY: CGFloat = 245
let barRect = NSRect(x: barX, y: barY, width: barWidth, height: barHeight)
let barCornerRadius: CGFloat = 16
let barPath = NSBezierPath(roundedRect: barRect, xRadius: barCornerRadius, yRadius: barCornerRadius)

// Soundbar Drop Shadow
cg.saveGState()
let barShadow = NSShadow()
barShadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
barShadow.shadowOffset = NSSize(width: 0, height: -10)
barShadow.shadowBlurRadius = 18
barShadow.set()

// Soundbar Body Gradient
let barColors =
  [
    NSColor(calibratedRed: 0.25, green: 0.27, blue: 0.33, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.20, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).cgColor,
  ] as CFArray
if let barGrad = CGGradient(
  colorsSpace: CGColorSpaceCreateDeviceRGB(),
  colors: barColors,
  locations: [0.0, 0.45, 1.0]
) {
  cg.saveGState()
  barPath.addClip()
  cg.drawLinearGradient(
    barGrad,
    start: CGPoint(x: size / 2, y: barY + barHeight),
    end: CGPoint(x: size / 2, y: barY),
    options: []
  )

  // Top specular highlight on soundbar
  let topHighlight = CGMutablePath()
  topHighlight.addRect(
    CGRect(x: barX + 12, y: barY + barHeight - 2.5, width: barWidth - 24, height: 2)
  )
  cg.addPath(topHighlight)
  cg.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.28).cgColor)
  cg.fillPath()

  // Left and Right Acoustic Speaker Driver Grilles
  let grilleY = barY + 16
  let grilleRadius: CGFloat = 13
  for gx in [barX + 50, barX + 95, barX + barWidth - 95, barX + barWidth - 50] {
    let circle = CGMutablePath()
    circle.addArc(
      center: CGPoint(x: gx, y: grilleY + grilleRadius),
      radius: grilleRadius,
      startAngle: 0,
      endAngle: .pi * 2,
      clockwise: true
    )
    cg.addPath(circle)
    cg.setFillColor(NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.06, alpha: 0.75).cgColor)
    cg.fillPath()

    // Subtle driver cone inner ring
    let innerCircle = CGMutablePath()
    innerCircle.addArc(
      center: CGPoint(x: gx, y: grilleY + grilleRadius),
      radius: grilleRadius * 0.45,
      startAngle: 0,
      endAngle: .pi * 2,
      clockwise: true
    )
    cg.addPath(innerCircle)
    cg.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.12).cgColor)
    cg.fillPath()
  }

  cg.restoreGState()
}
cg.restoreGState()

// Soundbar Perimeter Stroke
cg.saveGState()
cg.setLineWidth(1.5)
cg.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.18).cgColor)
barPath.stroke()
cg.restoreGState()

// 7. Signature Illuminated Center "AMBEO" LED Lightbar
let ledWidth: CGFloat = 90
let ledHeight: CGFloat = 7
let ledX = (size - ledWidth) / 2
let ledY = barY + (barHeight - ledHeight) / 2
let ledRect = NSRect(x: ledX, y: ledY, width: ledWidth, height: ledHeight)
let ledPath = NSBezierPath(roundedRect: ledRect, xRadius: 3.5, yRadius: 3.5)

cg.saveGState()
cg.setShadow(
  offset: CGSize.zero,
  blur: 20,
  color: NSColor(calibratedRed: 0.0, green: 0.95, blue: 1.0, alpha: 1.0).cgColor
)
NSColor(calibratedRed: 0.3, green: 1.0, blue: 1.0, alpha: 1.0).setFill()
ledPath.fill()
cg.restoreGState()

// 8. Soundbar Elevation Height Beams (Dolby Atmos / 3D Audio upward firing)
cg.saveGState()
for (bx, angle) in [(barX + 150, CGFloat.pi * 0.58), (barX + barWidth - 150, CGFloat.pi * 0.42)] {
  let beamPath = CGMutablePath()
  let beamLength: CGFloat = 160
  let endX = bx + cos(angle) * beamLength
  let endY = (barY + barHeight) + sin(angle) * beamLength
  beamPath.move(to: CGPoint(x: bx, y: barY + barHeight))
  beamPath.addLine(to: CGPoint(x: endX, y: endY))

  cg.setLineWidth(3.5)
  cg.setLineCap(.round)
  cg.setStrokeColor(NSColor(calibratedRed: 0.0, green: 0.9, blue: 1.0, alpha: 0.55).cgColor)
  cg.setShadow(
    offset: .zero,
    blur: 12,
    color: NSColor(calibratedRed: 0.0, green: 0.9, blue: 1.0, alpha: 0.6).cgColor
  )
  cg.addPath(beamPath)
  cg.strokePath()
}
cg.restoreGState()

// 9. Central Spatial Origin Core (Pulsing Acoustic Orb)
let orbCenter = CGPoint(x: size / 2, y: 355)
let orbRadius: CGFloat = 18

cg.saveGState()
cg.setShadow(
  offset: .zero,
  blur: 28,
  color: NSColor(calibratedRed: 0.0, green: 1.0, blue: 1.0, alpha: 1.0).cgColor
)
let orbPath = CGMutablePath()
orbPath.addArc(
  center: orbCenter,
  radius: orbRadius,
  startAngle: 0,
  endAngle: .pi * 2,
  clockwise: true
)
cg.addPath(orbPath)
cg.setFillColor(NSColor(calibratedRed: 0.85, green: 1.0, blue: 1.0, alpha: 1.0).cgColor)
cg.fillPath()
cg.restoreGState()

// 10. Inner Bevel Highlight along the Top Edge of the Squircle
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

// End squircle clip
cg.restoreGState()

// Outer subtle squircle rim border
cg.saveGState()
cg.setLineWidth(1.5)
cg.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.12).cgColor)
squirclePath.stroke()
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

print("🎉 Successfully generated \(icnsPath)!")
