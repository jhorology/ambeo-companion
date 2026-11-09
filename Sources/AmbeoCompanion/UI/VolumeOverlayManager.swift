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
  private var dismissTask: Task<Void, Never>?

  /// Applies `update` to the current overlay state, then presents it.
  /// Fields the closure does not touch keep their previous values.
  func show(_ update: (VolumeOverlayState) -> Void = { _ in }) {
    update(state)

    if panel == nil { createPanel() }
    guard let panel else { return }

    fitPanelToContent()
    updatePanelPosition()

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
    // The panel may carry a transparent shadow margin; align the visible card, not the window.
    let margin = (pf.width - (hostingView?.fittingSize.width ?? pf.width)) / 2
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

  /// Corner radius shared by the AppKit glass window and the SwiftUI fallback card.
  static let cornerRadius: CGFloat = 26

  private var hostingView: NSHostingView<VolumeOverlayView>?

  /// Shrinks the panel to the SwiftUI content so the window outline (and its system shadow) is the
  /// rounded card itself, as with the built-in volume and brightness OSDs.
  private func fitPanelToContent() {
    guard let panel, let hostingView else { return }
    hostingView.layoutSubtreeIfNeeded()
    let fitting = hostingView.fittingSize
    guard fitting.width > 0, fitting.height > 0 else { return }
    let size = panelSize(for: fitting)
    guard panel.frame.size != size else { return }
    panel.setContentSize(size)
    panel.invalidateShadow()
  }

  private func panelSize(for content: NSSize) -> NSSize {
    guard #available(macOS 26.0, *) else { return content }
    let margin = GlassOverlayContainerView.shadowMargin
    return NSSize(width: content.width + margin * 2, height: content.height + margin * 2)
  }

  private func createPanel() {
    let hosting = NSHostingView(rootView: VolumeOverlayView(state: state))
    hosting.sizingOptions = [.intrinsicContentSize]
    hostingView = hosting
    let initialSize = panelSize(for: hosting.fittingSize)

    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: initialSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .popUpMenu
    panel.backgroundColor = .clear
    panel.isOpaque = false
    // macOS 26+ draws its own elevation shadow inside the panel's transparent margin.
    if #available(macOS 26.0, *) { panel.hasShadow = false } else { panel.hasShadow = true }
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    if #available(macOS 26.0, *) {
      // The window itself is the glass, like the system OSDs: AppKit draws the rim highlight and
      // the shadow follows the rounded outline.
      panel.contentView = GlassOverlayContainerView(
        content: hosting,
        cornerRadius: Self.cornerRadius
      )
    } else {
      panel.contentView = hosting
    }

    self.panel = panel
    updatePanelPosition()
  }
}

// MARK: - Glass window content (macOS 26+)

/// Hosts the OSD in an `NSGlassEffectView` and gives it the lifted look of the system volume and
/// brightness OSDs: a wide, soft drop shadow plus a hairline outline that separates the rim from
/// light backgrounds. The standard borderless-window shadow is too tight for that, so the panel
/// carries a transparent margin and the shadow is drawn inside it.
@available(macOS 26.0, *) final class GlassOverlayContainerView: NSView {
  static let shadowMargin: CGFloat = 40

  private let cornerRadius: CGFloat
  private let shadowView = NSView()
  private let outline = CAShapeLayer()
  private let glass = NSGlassEffectView()

  init(content: NSView, cornerRadius: CGFloat) {
    self.cornerRadius = cornerRadius
    super.init(frame: .zero)
    wantsLayer = true

    shadowView.wantsLayer = true
    if let layer = shadowView.layer {
      layer.masksToBounds = false
      layer.shadowColor = NSColor.black.cgColor
      layer.shadowOpacity = 0.32
      layer.shadowRadius = 22
      layer.shadowOffset = CGSize(width: 0, height: -10)
      outline.fillColor = nil
      outline.strokeColor = NSColor.black.withAlphaComponent(0.22).cgColor
      outline.lineWidth = 1
      layer.addSublayer(outline)
    }
    addSubview(shadowView)

    glass.cornerRadius = cornerRadius
    glass.contentView = content
    addSubview(glass)
  }

  @available(*, unavailable) required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func layout() {
    super.layout()
    let card = bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
    glass.frame = card
    shadowView.frame = bounds

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shadowView.layer?.shadowPath = CGPath(
      roundedRect: card,
      cornerWidth: cornerRadius,
      cornerHeight: cornerRadius,
      transform: nil
    )
    // Half a point outside the glass so the hairline frames the rim instead of covering it.
    let ring = card.insetBy(dx: -0.5, dy: -0.5)
    outline.path = CGPath(
      roundedRect: ring,
      cornerWidth: cornerRadius + 0.5,
      cornerHeight: cornerRadius + 0.5,
      transform: nil
    )
    CATransaction.commit()
  }
}

// MARK: - Background

/// On macOS 26+ the panel's `NSGlassEffectView` is the background, so the content draws none.
/// Older systems keep the pre-Tahoe material card.
private struct OverlayGlassBackground: ViewModifier {
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    if #available(macOS 26.0, *) {
      content
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

/// Glass capsule (tinted when active) on macOS 26+, translucent fill on older systems.
private struct StatusPillBackground: ViewModifier {
  let isActive: Bool
  let activeColor: Color

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.glassEffect(
        isActive ? .regular.tint(activeColor.opacity(0.35)) : .regular,
        in: .capsule
      )
    } else {
      content.background {
        Capsule().fill(isActive ? activeColor.opacity(0.15) : Color.white.opacity(0.05)).overlay {
          if isActive { Capsule().strokeBorder(activeColor.opacity(0.35), lineWidth: 0.5) }
        }
      }
    }
  }
}

// MARK: - SwiftUI View

struct VolumeOverlayView: View {
  var state: VolumeOverlayState

  private let ledCyan = Color(red: 0.15, green: 0.78, blue: 1.0)
  private let ledPurple = Color(red: 0.75, green: 0.35, blue: 1.0)
  private let ledWhite = Color(red: 0.75, green: 0.75, blue: 0.75)
  private let ledDim = Color.white.opacity(0.18)

  @State private var flashOpacity: Double = 1.0

  private var activeLedColor: Color {
    if state.isNightMode {
      return ledPurple
    } else if state.isVoiceEnhancement {
      return ledCyan
    } else if state.isAmbeoMode {
      return ledWhite
    } else {
      return ledDim
    }
  }

  /// AMBEO brightness based on level:
  /// Off: dim (0.2)
  /// Light: subtle glow (0.55)
  /// Standard: medium glow (0.8)
  /// Boost: full brightness (1.0)
  private var logoBrightnessMultiplier: Double {
    guard state.isAmbeoMode else { return 0.25 }
    switch state.ambeoLevel.lowercased() {
    case "light": return 0.55
    case "boost": return 1.0
    default: return 0.8
    }
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
          ).frame(width: 24)

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
          activeColor: .secondary
        )

        statusPill(
          icon: "power",
          title: state.powerTarget == "online" ? "On" : "Stby",
          isActive: state.powerTarget == "online",
          activeColor: .green
        )
      }
    }.padding(.vertical, 16).padding(.horizontal, 20).modifier(
      OverlayGlassBackground(cornerRadius: VolumeOverlayManager.cornerRadius)
    ).frame(width: 320).animation(.smooth(duration: 0.25), value: state.isNightMode).animation(
      .smooth(duration: 0.25),
      value: state.isAmbeoMode
    ).animation(.smooth(duration: 0.15), value: state.volume).animation(
      .smooth(duration: 0.15),
      value: state.isMuted
    ).onChange(of: state.ambeoLevel) { _, _ in triggerFlashAnimation() }.onChange(
      of: state.isAmbeoMode
    ) { _, isAmbeo in if isAmbeo { triggerFlashAnimation() } }
  }

  private func triggerFlashAnimation() {
    guard state.isAmbeoMode else { return }
    let count = flashCount
    Task { @MainActor in
      for _ in 0..<count {
        withAnimation(.easeOut(duration: 0.1)) { flashOpacity = 0.2 }
        try? await Task.sleep(for: .milliseconds(110))
        withAnimation(.easeIn(duration: 0.12)) { flashOpacity = 1.0 }
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
        Capsule().fill(state.isMuted ? Color.secondary : activeLedColor).frame(
          width: max(0, width * progress),
          height: height
        ).shadow(color: state.isMuted ? .clear : activeLedColor.opacity(0.4), radius: 3, x: 0, y: 0)

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
        // Product LED-style AMBEO text with brightness modulation and flash
        Text("AMBΞO").font(.system(size: 17, weight: .heavy, design: .default)).tracking(3.5)
          .foregroundStyle(activeLedColor.opacity(logoBrightnessMultiplier * flashOpacity)).shadow(
            color: (state.isNightMode || state.isAmbeoMode)
              ? activeLedColor.opacity(0.9 * logoBrightnessMultiplier * flashOpacity) : .clear,
            radius: 6,
            x: 0,
            y: 0
          ).shadow(
            color: (state.isNightMode || state.isAmbeoMode)
              ? activeLedColor.opacity(0.4 * logoBrightnessMultiplier * flashOpacity) : .clear,
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
    ).modifier(StatusPillBackground(isActive: isActive, activeColor: activeColor))
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
