import AppKit
import SwiftUI

// MARK: - Observable state shared with the SwiftUI view

@Observable @MainActor final class VolumeOverlayState {
  var volume: Double = 0
  var isMuted: Bool = false
  var isAmbeoMode: Bool = true
  var ambeoLevel: String = "standard"  // "light", "standard", "boost"
  var isNightMode: Bool = false
  var isVoiceEnhancement: Bool = false
  var isEcoMode: Bool = false
  var maxIdleTime: Int = 900  // seconds (0=off, 300=5m, 600=10m, 900=15m, 1800=30m)
  var powerTarget: String = "online"  // "online", "networkStandby", "standby"
  var audioPreset: String? = nil  // "adaptive", "music", "movie", etc.
  var isAtmos: Bool = false
}

// MARK: - Manager (MainActor)

@MainActor final class VolumeOverlayManager {
  private var panel: NSPanel?
  let state = VolumeOverlayState()
  var position: OverlayPosition = .center

  /// Gap between the visible card and the menu bar / screen edge for the top positions.
  private static let edgeInset: CGFloat = 12
  /// Transparent margin around the card so Liquid Glass bleed (42pt) and elevation shadow
  /// render without clipping at the borderless window bounds.
  static let shadowMargin: CGFloat = 44

  private static var effectiveShadowMargin: CGFloat {
    if #available(macOS 26.0, *) { return shadowMargin }
    return 0
  }

  private var dismissTask: Task<Void, Never>?

  /// Applies `update` to the current overlay state, then presents it.
  /// Fields the closure does not touch keep their previous values.
  func show(_ update: (VolumeOverlayState) -> Void = { _ in }) {
    update(state)

    if panel == nil { createPanel() }
    guard let panel else { return }

    fitPanelToContent()
    updatePanelPosition()
    hostingView?.applyGlassTranslucency()

    // Cancel existing dismissal task
    dismissTask?.cancel()

    // Standard macOS OSD fluid entrance (fade-in)
    if !panel.isVisible || panel.alphaValue < 0.05 {
      panel.alphaValue = 0.0
      panel.orderFront(nil)
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.12
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1.0
      }
    } else if panel.alphaValue < 1.0 {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.08
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1.0
      }
    }

    // Standard macOS OSD smooth exit: gentle fade-out after 1.8s hold
    dismissTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1800))
      guard !Task.isCancelled else { return }
      guard let self, let p = self.panel else { return }

      NSAnimationContext.runAnimationGroup(
        { context in
          context.duration = 0.35
          context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          p.animator().alphaValue = 0.0
        },
        completionHandler: {
          MainActor.assumeIsolated { if p.alphaValue == 0.0 { p.orderOut(nil) } }
        }
      )
    }
  }

  private func updatePanelPosition() {
    guard let panel else { return }
    let mouseLoc = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main
    guard let screen else { return }
    let sf = screen.visibleFrame
    let pf = panel.frame
    // The panel carries a transparent shadow/bleed margin; align the visible card, not the window.
    let margin = Self.effectiveShadowMargin
    let inset = Self.edgeInset
    let topY = sf.maxY - inset - pf.height + margin
    let origin: NSPoint
    switch position {
    case .center: origin = NSPoint(x: sf.midX - pf.width / 2, y: sf.midY - pf.height / 2)
    case .topCenter: origin = NSPoint(x: sf.midX - pf.width / 2, y: topY)
    case .topRight: origin = NSPoint(x: sf.maxX - inset - pf.width + margin, y: topY)
    }
    panel.setFrameOrigin(origin)
  }

  /// Corner radius shared by the Liquid Glass platter and the pre-Tahoe fallback card.
  static let cornerRadius: CGFloat = 26

  private var hostingView: OverlayHostingView?

  /// Sizes the panel to the SwiftUI content (including its transparent shadow/bleed margin on
  /// macOS 26+) so the Liquid Glass platter and its elevation shadow never clip.
  private func fitPanelToContent() {
    guard let panel, let hostingView else { return }
    hostingView.layoutSubtreeIfNeeded()
    let fitting = hostingView.fittingSize
    guard fitting.width > 0, fitting.height > 0 else { return }
    guard panel.frame.size != fitting else { return }
    panel.setContentSize(fitting)
    panel.invalidateShadow()
  }

  private func createPanel() {
    let hosting = OverlayHostingView(rootView: VolumeOverlayView(state: state))
    hosting.sizingOptions = [.intrinsicContentSize]
    hostingView = hosting
    let initialSize = hosting.fittingSize

    let panel = OverlayGlassPanel(
      contentRect: NSRect(origin: .zero, size: initialSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .popUpMenu
    panel.backgroundColor = .clear
    panel.isOpaque = false
    // Native macOS OSDs maintain a consistent appearance across Light and Dark modes while
    // refracting the screen behind them via WindowServer-aware backdrops.
    panel.appearance = NSAppearance(named: .darkAqua)
    // macOS 26+ draws its own Liquid Glass elevation shadow inside the transparent margin.
    if #available(macOS 26.0, *) { panel.hasShadow = false } else { panel.hasShadow = true }
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = hosting

    self.panel = panel
    updatePanelPosition()
  }
}

// MARK: - Active-appearance non-activating panel

/// Mirrors `SystemBannerUI.SystemBannerWindow`: a `.nonactivatingPanel` that never steals focus
/// from the active app, but reports active/key appearance to AppKit so Liquid Glass (`SDFLayer` /
/// `CABackdropLayer`) enables WindowServer backdrop refraction (`windowServerAware = 1`), full
/// 3D edge lensing curvature, and directional specular rim highlights.
private final class OverlayGlassPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  @objc func hasKeyAppearance() -> Bool { true }
  @objc func _hasKeyAppearance() -> Bool { true }
  @objc func _hasActiveAppearance() -> Bool { true }
  @objc func _hasActiveControls() -> Bool { true }
}

/// Tunes the `CABackdropLayer`'s `glassBackground` filter in `.darkAqua` so the OSD platter has
/// slightly higher translucency while preserving full 3D refraction, specular rim highlights, and
/// elevation shadow.
private final class OverlayHostingView: NSHostingView<VolumeOverlayView> {
  private static let darkenOpacity: Double = 0.55
  private static let maxLuma: Double = 0.60
  private static let blurRadius: Double = 3.5

  override func layout() {
    super.layout()
    applyGlassTranslucency()
    DispatchQueue.main.async { [weak self] in self?.applyGlassTranslucency() }
  }

  func applyGlassTranslucency() {
    guard #available(macOS 26.0, *), let root = self.layer else { return }
    Self.tuneGlassBackdrop(in: root)
  }

  private static func tuneGlassBackdrop(in layer: CALayer) {
    if String(describing: type(of: layer)) == "CABackdropLayer",
      let filters = layer.filters as? [NSObject]
    {
      var changed = false
      for filter in filters where filter.value(forKey: "name") as? String == "glassBackground" {
        if (filter.value(forKey: "inputBlurFillDarkenOpacity") as? Double) != darkenOpacity {
          filter.setValue(darkenOpacity, forKey: "inputBlurFillDarkenOpacity")
          filter.setValue(maxLuma, forKey: "inputFaceColorMatrixMaxLuma")
          filter.setValue(maxLuma, forKey: "inputFaceColorMatrixMaxLumaSDR")
          filter.setValue(blurRadius, forKey: "inputBlurRadius")
          changed = true
        }
      }
      if changed { layer.filters = filters }
    }
    for sublayer in layer.sublayers ?? [] { tuneGlassBackdrop(in: sublayer) }
  }
}

// MARK: - Background

/// On macOS 26+ applies the native Liquid Glass platter directly in the SwiftUI render tree
/// (avoiding nested `NSHostingView`/`CAPortalLayer` vibrancy conflicts with inner glass pills)
/// and pads by `shadowMargin` so the 42pt ambient bleed and elevation shadow are unclipped.
private struct OverlayGlassBackground: ViewModifier {
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    if #available(macOS 26.0, *) {
      content.glassEffect(.regular, in: shape).padding(VolumeOverlayManager.shadowMargin)
    } else {
      content.background {
        shape.fill(.ultraThinMaterial).overlay {
          shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }.shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
      }
    }
  }
}

/// Groups the status pills so their glass capsules render and blend as one Liquid Glass layer.
private struct StatusPillRow<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: 6) { HStack(spacing: 6) { content } }
    } else {
      HStack(spacing: 6) { content }
    }
  }
}

/// Untinted glass capsule on macOS 26+, translucent fill on older systems.
private struct StatusPillBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.glassEffect(.regular, in: .capsule)
    } else {
      content.background { Capsule().fill(Color.white.opacity(0.06)) }
    }
  }
}

// MARK: - SwiftUI View

struct VolumeOverlayView: View {
  var state: VolumeOverlayState

  private let ledCyan = Color(red: 0.15, green: 0.78, blue: 1.0)
  private let ledPurple = Color(red: 0.75, green: 0.35, blue: 1.0)

  @State private var flashIntensity: Double = 1.0

  /// Opaque (`opacity = 1.0`) accent color for the slider bar, ATMOS badge, and preset label.
  private var activeLedColor: Color {
    if state.isNightMode {
      return ledPurple
    } else if state.isVoiceEnhancement {
      return ledCyan
    } else {
      return .white
    }
  }

  /// Opaque (`opacity = 1.0`) color for the `AMBΞO` logo that expresses AMBEO Level
  /// (`off` / `light` / `standard` / `boost`) via saturation and brightness instead of alpha.
  private var ambeoLogoColor: Color {
    guard state.isAmbeoMode else { return Color(white: 0.38) }
    let saturationScale: Double
    let brightnessScale: Double
    switch state.ambeoLevel.lowercased() {
    case "light":
      saturationScale = 0.42
      brightnessScale = 0.65
    case "boost":
      saturationScale = 1.0
      brightnessScale = 1.0
    default:
      saturationScale = 0.72
      brightnessScale = 0.84
    }
    let s = saturationScale * flashIntensity
    let b = max(0.38, brightnessScale * flashIntensity)
    if state.isNightMode {
      return Color(hue: 0.76, saturation: 0.85 * s, brightness: b)
    } else if state.isVoiceEnhancement {
      return Color(hue: 0.54, saturation: 0.88 * s, brightness: b)
    } else {
      return Color(white: b)
    }
  }

  private var logoGlowIntensity: Double {
    guard state.isAmbeoMode else { return 0.0 }
    let base: Double
    switch state.ambeoLevel.lowercased() {
    case "light": base = 0.45
    case "boost": base = 1.0
    default: base = 0.75
    }
    return base * flashIntensity
  }

  private var flashCount: Int {
    switch state.ambeoLevel.lowercased() {
    case "light": return 1
    case "boost": return 3
    default: return 2
    }
  }

  var body: some View {
    VStack(spacing: 12) {
      // 1. AMBEO LED Brand Logo Header
      ambeoLogoHeader

      // 2. Volume Slider & Icon
      VStack(spacing: 6) {
        HStack(spacing: 12) {
          Image(systemName: iconName).font(.system(size: 20, weight: .light)).foregroundStyle(
            .primary
          ).frame(width: 24, height: 24)

          volumeGaugeWithTicks

          Text(state.isMuted ? "Muted" : "\(Int(state.volume * 100))%").font(
            .system(size: 13, weight: .semibold, design: .rounded)
          ).monospacedDigit().foregroundStyle(state.isMuted ? .secondary : .primary).frame(
            width: 44,
            alignment: .trailing
          )
        }
      }

      // 3. Status Badges Grid
      StatusPillRow {
        statusPill(
          icon: "moon.fill",
          title: "Night",
          isActive: state.isNightMode,
          activeColor: ledPurple
        )

        statusPill(
          icon: "waveform.and.person.filled",
          title: "Voice",
          isActive: state.isVoiceEnhancement,
          activeColor: .cyan
        )

        statusPill(icon: "leaf.fill", title: "Eco", isActive: state.isEcoMode, activeColor: .green)

        statusPill(
          icon: "clock.badge.checkmark",
          title: formatStandby(state.maxIdleTime),
          isActive: state.maxIdleTime > 0,
          activeColor: .white.opacity(0.85)
        )

        statusPill(
          icon: "power",
          title: state.powerTarget == "online" ? "On" : "Stby",
          isActive: state.powerTarget == "online",
          activeColor: .green
        )
      }
    }.padding(.vertical, 16).padding(.horizontal, 20).frame(width: 320).modifier(
      OverlayGlassBackground(cornerRadius: VolumeOverlayManager.cornerRadius)
    ).environment(\.colorScheme, .dark).animation(.smooth(duration: 0.25), value: state.isNightMode)
      .animation(.smooth(duration: 0.25), value: state.isAmbeoMode).animation(
        .smooth(duration: 0.15),
        value: state.volume
      ).animation(.smooth(duration: 0.15), value: state.isMuted).onChange(of: state.ambeoLevel) {
        _,
        _ in triggerFlashAnimation()
      }.onChange(of: state.isAmbeoMode) { _, isAmbeo in if isAmbeo { triggerFlashAnimation() } }
  }

  private func triggerFlashAnimation() {
    guard state.isAmbeoMode else { return }
    let count = flashCount
    Task { @MainActor in
      for _ in 0..<count {
        withAnimation(.easeOut(duration: 0.1)) { flashIntensity = 0.45 }
        try? await Task.sleep(for: .milliseconds(110))
        withAnimation(.easeIn(duration: 0.12)) { flashIntensity = 1.0 }
        try? await Task.sleep(for: .milliseconds(130))
      }
    }
  }

  // MARK: - Volume Gauge with Ticks

  private var volumeGaugeWithTicks: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let height: CGFloat = 6
      let progress = state.isMuted ? 0.0 : max(0.0, min(1.0, state.volume))

      ZStack(alignment: .leading) {
        // Track Background
        Capsule().fill(Color.white.opacity(0.12)).frame(height: height)

        // Progress Fill
        Capsule().fill(activeLedColor).frame(width: max(0, width * progress), height: height)
          .shadow(
            color: state.isMuted ? .clear : activeLedColor.opacity(0.4),
            radius: 3,
            x: 0,
            y: 0
          )

        // Tick marks (every 25%: 0%, 25%, 50%, 75%, 100%)
        HStack {
          ForEach(0...4, id: \.self) { i in
            if i > 0 { Spacer() }
            Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: height + 4)
          }
        }.allowsHitTesting(false)
      }.frame(height: geo.size.height, alignment: .center)
    }.frame(height: 12)
  }

  // MARK: - AMBEO LED Logo

  private var ambeoLogoHeader: some View {
    HStack(alignment: .center, spacing: 10) {
      // Left side: AMBEO logo & optional DOLBY ATMOS
      HStack(alignment: .center, spacing: 10) {
        // Product LED-style AMBEO text with opaque saturation/brightness modulation and flash
        Text("AMBΞO").font(.system(size: 17, weight: .heavy, design: .default)).tracking(3.5)
          .foregroundStyle(ambeoLogoColor).shadow(
            color: state.isAmbeoMode ? ambeoLogoColor.opacity(0.9 * logoGlowIntensity) : .clear,
            radius: 6,
            x: 0,
            y: 0
          ).shadow(
            color: state.isAmbeoMode ? ambeoLogoColor.opacity(0.4 * logoGlowIntensity) : .clear,
            radius: 14,
            x: 0,
            y: 0
          )

        if state.isAtmos { dolbyAtmosBadge.transition(.opacity) }
      }

      Spacer(minLength: 0)

      // Right side: Preset (pinned to right so it doesn't shift when Atmos toggles)
      if let preset = state.audioPreset {
        HStack(spacing: 4) {
          Image(systemName: presetIcon(preset.lowercased())).font(.system(size: 10, weight: .bold))
          Text(preset.uppercased()).font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(0.8)
        }.foregroundStyle(activeLedColor).shadow(
          color: activeLedColor.opacity(0.8),
          radius: 5,
          x: 0,
          y: 0
        ).shadow(color: activeLedColor.opacity(0.35), radius: 10, x: 0, y: 0)
      }
    }.padding(.bottom, 2)
  }

  // Custom Dolby Double-D icon + ATMOS text
  private var dolbyAtmosBadge: some View {
    HStack(spacing: 4.5) {
      dolbyDoubleDIcon
      Text("ATMOS").font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(0.8)
    }.foregroundStyle(activeLedColor).shadow(
      color: activeLedColor.opacity(0.8),
      radius: 5,
      x: 0,
      y: 0
    ).shadow(color: activeLedColor.opacity(0.35), radius: 10, x: 0, y: 0)
  }

  /// Official-style Dolby logo (two D shapes facing each other: Dᗡ)
  private var dolbyDoubleDIcon: some View {
    HStack(spacing: 1.5) {
      // Left D (standard D: flat back on left, curved belly on right facing inward)
      Rectangle().fill(activeLedColor).frame(width: 5, height: 9).clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: 0,
          bottomLeadingRadius: 0,
          bottomTrailingRadius: 3.5,
          topTrailingRadius: 3.5
        )
      ).overlay {
        // Hollow cut inside left D
        UnevenRoundedRectangle(
          topLeadingRadius: 0,
          bottomLeadingRadius: 0,
          bottomTrailingRadius: 2,
          topTrailingRadius: 2
        ).stroke(Color.black.opacity(0.6), lineWidth: 1.2)
      }

      // Right D (mirrored D: curved belly on left facing inward, flat back on right)
      Rectangle().fill(activeLedColor).frame(width: 5, height: 9).clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: 3.5,
          bottomLeadingRadius: 3.5,
          bottomTrailingRadius: 0,
          topTrailingRadius: 0
        )
      ).overlay {
        // Hollow cut inside right D
        UnevenRoundedRectangle(
          topLeadingRadius: 2,
          bottomLeadingRadius: 2,
          bottomTrailingRadius: 0,
          topTrailingRadius: 0
        ).stroke(Color.black.opacity(0.6), lineWidth: 1.2)
      }
    }
  }

  private func presetIcon(_ preset: String) -> String {
    switch preset {
    case "adaptive": return "wand.and.stars"
    case "music": return "music.note"
    case "movie": return "film"
    case "news": return "newspaper"
    case "sports": return "sportscourt"
    default: return "slider.horizontal.3"
    }
  }

  // MARK: - Status Pill Helper

  private func statusPill(
    icon: String,
    title: String,
    isActive: Bool,
    activeColor: Color
  ) -> some View {
    HStack(spacing: 3.5) {
      Image(systemName: icon).font(.system(size: 9, weight: .bold))
      Text(title).font(.system(size: 9, weight: .semibold, design: .rounded))
    }.padding(.horizontal, 6).padding(.vertical, 4).foregroundStyle(
      isActive ? activeColor : Color.secondary.opacity(0.6)
    ).modifier(StatusPillBackground())
  }

  private func formatStandby(_ seconds: Int) -> String {
    if seconds == 0 { return "NoStby" }
    return "\(seconds / 60)m"
  }

  private var iconName: String {
    if state.isMuted || state.volume < 0.005 { return "speaker.slash.fill" }
    if state.volume < 0.34 { return "speaker.wave.1.fill" }
    if state.volume < 0.67 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
  }
}
