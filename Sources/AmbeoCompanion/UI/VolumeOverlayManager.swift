import AppKit
import SwiftUI

// MARK: - Observable state shared with the SwiftUI view

@Observable
@MainActor
final class VolumeOverlayState {
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

@MainActor
final class VolumeOverlayManager {
  private var panel: NSPanel?
  let state = VolumeOverlayState()
  private var dismissTask: Task<Void, Never>?

  /// Applies `update` to the current overlay state, then presents it.
  /// Fields the closure does not touch keep their previous values.
  func show(_ update: (VolumeOverlayState) -> Void = { _ in }) {
    update(state)

    if panel == nil { createPanel() }
    guard let panel else { return }

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
          MainActor.assumeIsolated {
            if p.alphaValue == 0.0 {
              p.orderOut(nil)
            }
          }
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
    panel.setFrameOrigin(
      NSPoint(x: sf.midX - pf.width / 2, y: sf.midY - pf.height / 2)
    )
  }

  private func createPanel() {
    let hosting = NSHostingView(rootView: VolumeOverlayView(state: state))
    hosting.translatesAutoresizingMaskIntoConstraints = false

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 210),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .popUpMenu
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
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
          Image(systemName: iconName)
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(.primary)
            .frame(width: 24)

          volumeGaugeWithTicks

          Text(state.isMuted ? "Muted" : "\(Int(state.volume * 100))%")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(state.isMuted ? .secondary : .primary)
            .frame(width: 44, alignment: .trailing)
        }
      }

      // 3. Status Badges Grid
      HStack(spacing: 6) {
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

        statusPill(
          icon: "leaf.fill",
          title: "Eco",
          isActive: state.isEcoMode,
          activeColor: .green
        )

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
    }
    .padding(.vertical, 16)
    .padding(.horizontal, 20)
    .background {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay {
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
    }
    .frame(width: 320)
    .animation(.smooth(duration: 0.25), value: state.isNightMode)
    .animation(.smooth(duration: 0.25), value: state.isAmbeoMode)
    .animation(.smooth(duration: 0.15), value: state.volume)
    .animation(.smooth(duration: 0.15), value: state.isMuted)
    .onChange(of: state.ambeoLevel) { _, _ in
      triggerFlashAnimation()
    }
    .onChange(of: state.isAmbeoMode) { _, isAmbeo in
      if isAmbeo {
        triggerFlashAnimation()
      }
    }
  }

  private func triggerFlashAnimation() {
    guard state.isAmbeoMode else { return }
    let count = flashCount
    Task { @MainActor in
      for _ in 0..<count {
        withAnimation(.easeOut(duration: 0.1)) {
          flashOpacity = 0.2
        }
        try? await Task.sleep(for: .milliseconds(110))
        withAnimation(.easeIn(duration: 0.12)) {
          flashOpacity = 1.0
        }
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
        Capsule()
          .fill(Color.white.opacity(0.12))
          .frame(height: height)

        // Progress Fill
        Capsule()
          .fill(state.isMuted ? Color.secondary : activeLedColor)
          .frame(width: max(0, width * progress), height: height)
          .shadow(
            color: state.isMuted ? .clear : activeLedColor.opacity(0.4),
            radius: 3,
            x: 0,
            y: 0
          )

        // Tick marks (every 25%: 0%, 25%, 50%, 75%, 100%)
        HStack {
          ForEach(0...4, id: \.self) { i in
            if i > 0 {
              Spacer()
            }
            Rectangle()
              .fill(Color.white.opacity(0.35))
              .frame(width: 1, height: height + 4)
          }
        }
        .allowsHitTesting(false)
      }
      .frame(height: geo.size.height, alignment: .center)
    }
    .frame(height: 12)
  }

  // MARK: - AMBEO LED Logo

  private var ambeoLogoHeader: some View {
    HStack(alignment: .center, spacing: 10) {
      // Left side: AMBEO logo & optional DOLBY ATMOS
      HStack(alignment: .center, spacing: 10) {
        // Product LED-style AMBEO text with brightness modulation and flash
        Text("AMBΞO")
          .font(.system(size: 17, weight: .heavy, design: .default))
          .tracking(3.5)
          .foregroundStyle(activeLedColor.opacity(logoBrightnessMultiplier * flashOpacity))
          .shadow(
            color: (state.isNightMode || state.isAmbeoMode)
              ? activeLedColor.opacity(0.9 * logoBrightnessMultiplier * flashOpacity) : .clear,
            radius: 6,
            x: 0,
            y: 0
          )
          .shadow(
            color: (state.isNightMode || state.isAmbeoMode)
              ? activeLedColor.opacity(0.4 * logoBrightnessMultiplier * flashOpacity) : .clear,
            radius: 14,
            x: 0,
            y: 0
          )

        if state.isAtmos {
          dolbyAtmosBadge
            .transition(.opacity)
        }
      }

      Spacer(minLength: 0)

      // Right side: Preset (pinned to right so it doesn't shift when Atmos toggles)
      if let preset = state.audioPreset {
        HStack(spacing: 4) {
          Image(systemName: presetIcon(preset.lowercased()))
            .font(.system(size: 10, weight: .bold))
          Text(preset.uppercased())
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(0.8)
        }
        .foregroundStyle(activeLedColor)
        .shadow(
          color: activeLedColor.opacity(0.8),
          radius: 5,
          x: 0,
          y: 0
        )
        .shadow(
          color: activeLedColor.opacity(0.35),
          radius: 10,
          x: 0,
          y: 0
        )
      }
    }
    .padding(.bottom, 2)
  }

  // Custom Dolby Double-D icon + ATMOS text
  private var dolbyAtmosBadge: some View {
    HStack(spacing: 4.5) {
      dolbyDoubleDIcon
      Text("ATMOS")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(0.8)
    }
    .foregroundStyle(activeLedColor)
    .shadow(
      color: activeLedColor.opacity(0.8),
      radius: 5,
      x: 0,
      y: 0
    )
    .shadow(
      color: activeLedColor.opacity(0.35),
      radius: 10,
      x: 0,
      y: 0
    )
  }

  /// Official-style Dolby logo (two D shapes facing each other: Dᗡ)
  private var dolbyDoubleDIcon: some View {
    HStack(spacing: 1.5) {
      // Left D (standard D: flat back on left, curved belly on right facing inward)
      Rectangle()
        .fill(activeLedColor)
        .frame(width: 5, height: 9)
        .clipShape(
          UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 3.5,
            topTrailingRadius: 3.5
          )
        )
        .overlay {
          // Hollow cut inside left D
          UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 2,
            topTrailingRadius: 2
          )
          .stroke(Color.black.opacity(0.6), lineWidth: 1.2)
        }

      // Right D (mirrored D: curved belly on left facing inward, flat back on right)
      Rectangle()
        .fill(activeLedColor)
        .frame(width: 5, height: 9)
        .clipShape(
          UnevenRoundedRectangle(
            topLeadingRadius: 3.5,
            bottomLeadingRadius: 3.5,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0
          )
        )
        .overlay {
          // Hollow cut inside right D
          UnevenRoundedRectangle(
            topLeadingRadius: 2,
            bottomLeadingRadius: 2,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0
          )
          .stroke(Color.black.opacity(0.6), lineWidth: 1.2)
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
      Image(systemName: icon)
        .font(.system(size: 9, weight: .bold))
      Text(title)
        .font(.system(size: 9, weight: .semibold, design: .rounded))
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .foregroundStyle(isActive ? activeColor : Color.secondary.opacity(0.6))
    .background {
      Capsule()
        .fill(isActive ? activeColor.opacity(0.15) : Color.white.opacity(0.05))
        .overlay {
          if isActive {
            Capsule().strokeBorder(activeColor.opacity(0.35), lineWidth: 0.5)
          }
        }
    }
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
