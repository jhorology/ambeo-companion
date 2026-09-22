import AppKit
import SwiftUI

// MARK: - Observable state shared with the SwiftUI view

@Observable
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

  /// Show the overlay with updated status information.
  func show(
    volume: Double? = nil,
    isMuted: Bool? = nil,
    isAmbeoMode: Bool? = nil,
    ambeoLevel: String? = nil,
    isNightMode: Bool? = nil,
    isVoiceEnhancement: Bool? = nil,
    isEcoMode: Bool? = nil,
    maxIdleTime: Int? = nil,
    powerTarget: String? = nil,
    audioPreset: String? = nil,
    isAtmos: Bool? = nil
  ) {
    if let v = volume { state.volume = v }
    if let m = isMuted { state.isMuted = m }
    if let a = isAmbeoMode { state.isAmbeoMode = a }
    if let al = ambeoLevel { state.ambeoLevel = al }
    if let nm = isNightMode { state.isNightMode = nm }
    if let ve = isVoiceEnhancement { state.isVoiceEnhancement = ve }
    if let eco = isEcoMode { state.isEcoMode = eco }
    if let mit = maxIdleTime { state.maxIdleTime = mit }
    if let pt = powerTarget { state.powerTarget = pt }
    if let ap = audioPreset { state.audioPreset = ap }
    if let at = isAtmos { state.isAtmos = at }

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
    let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main
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
  private let ledDim = Color.white.opacity(0.18)

  private var activeLedColor: Color {
    if state.isNightMode {
      return ledPurple
    } else if state.isAmbeoMode {
      return ledCyan
    } else {
      return ledDim
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
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(.primary)
            .frame(width: 26)

          Gauge(value: state.isMuted ? 0 : state.volume) {}
            .gaugeStyle(.accessoryLinear)
            .tint(state.isMuted ? Color.secondary : activeLedColor)

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
  }

  // MARK: - AMBEO LED Logo

  private var ambeoLogoHeader: some View {
    HStack(alignment: .center, spacing: 8) {
      // Product LED-style AMBEO text
      Text("AMBEO")
        .font(.system(size: 17, weight: .heavy, design: .default))
        .tracking(3.5)
        .foregroundStyle(activeLedColor)
        .shadow(
          color: (state.isNightMode || state.isAmbeoMode) ? activeLedColor.opacity(0.9) : .clear,
          radius: 6,
          x: 0,
          y: 0
        )
        .shadow(
          color: (state.isNightMode || state.isAmbeoMode) ? activeLedColor.opacity(0.4) : .clear,
          radius: 14,
          x: 0,
          y: 0
        )

      Spacer()

      // Preset & AMBEO 3D Level Indicator
      HStack(spacing: 5) {
        if state.isAtmos {
          Text("ATMOS")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(ledCyan)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(ledCyan.opacity(0.18)))
            .overlay(Capsule().strokeBorder(ledCyan.opacity(0.5), lineWidth: 0.8))
        }

        if let preset = state.audioPreset {
          Text(preset.capitalized)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }

        if state.isAmbeoMode {
          HStack(spacing: 2.5) {
            ForEach(0..<3) { idx in
              RoundedRectangle(cornerRadius: 1)
                .fill(idx <= levelIndex ? activeLedColor : Color.white.opacity(0.15))
                .frame(width: 3, height: 8 + CGFloat(idx) * 2)
            }
          }
          .padding(.leading, 2)

          Text(state.ambeoLevel.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(activeLedColor)
        } else {
          Text("OFF")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(ledDim)
        }
      }
    }
    .padding(.bottom, 2)
  }

  private var levelIndex: Int {
    switch state.ambeoLevel.lowercased() {
    case "light": return 0
    case "boost": return 2
    default: return 1  // standard
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
