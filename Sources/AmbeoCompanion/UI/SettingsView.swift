import AmbeoCore
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var appModel

  /// Dynamic lists that are not persisted
  @State private var availableAudioDevices: [AudioDevice] = []
  @State private var supportedFormats: [AudioPhysicalFormat] = []

  var body: some View {
    @Bindable var model = appModel

    Form {
      // --- Section 1: Network Device ---
      Section {
        LabeledDescription(
          title: "AMBEO Soundbar",
          subtitle: "Choose the AMBEO Soundbar to control over your local network."
        ) {
          Picker("", selection: $model.settings.ambeoUid) {
            if model.settings.ambeoUid.isEmpty {
              Text(appModel.networkDevices.isEmpty ? "Searching..." : "Select a device").tag("")
            }
            ForEach(appModel.networkDevices) { device in
              Text(device.name).tag(device.uuid)
            }
          }
          .labelsHidden()
        }
      } header: {
        Text("Network Device")
      }

      // --- Section 2: Audio Device ---
      Section {
        LabeledDescription(
          title: "Sound Output",
          subtitle:
            "Choose the physical audio output for your AMBEO soundbar. If connected via eARC, this is typically the display's audio device."
        ) {
          Picker("", selection: $model.settings.audioDeviceUid) {
            if model.settings.audioDeviceUid.isEmpty {
              Text("Select a device").tag("")
            }
            ForEach(availableAudioDevices) { device in
              Text(device.name).tag(device.uid)
            }
          }
          .onChange(of: model.settings.audioDeviceUid) { _, newUID in
            refreshFormats(for: newUID, current: model.settings.fallbackAudioFormatID)
          }
          .labelsHidden()
        }

        LabeledDescription(
          title: "Fallback Format",
          subtitle:
            "Format applied when Dolby Atmos passthrough is inactive, preventing macOS from defaulting to 192 kHz."
        ) {
          Picker("", selection: $model.settings.fallbackAudioFormatID) {
            ForEach(supportedFormats) { format in
              Text(format.displayName).tag(format.id)
            }
          }
          .disabled(supportedFormats.isEmpty)
          .labelsHidden()
        }

        #if DEBUG
        LabeledDescription(title: "Fallback Test", subtitle: "") {
          Button("Execute", systemImage: "ladybug.circle") {
            applyFallbackNow(
              formatID: model.settings.fallbackAudioFormatID,
              deviceUID: model.settings.audioDeviceUid
            )
          }
          .disabled(
            model.settings.fallbackAudioFormatID.isEmpty
              || model.settings.audioDeviceUid.isEmpty
          )
        }
        #endif
      } header: {
        Text("Target Audio Device")
      }

      // --- Section 3: Behavior ---
      Section {
        LabeledDescription(
          title: "Launch at Login",
          subtitle: "Automatically start Ambeo Companion when you log in to your Mac."
        ) {
          Toggle("", isOn: $model.isLaunchAtLoginEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        LabeledDescription(
          title: "Media Key Interception",
          subtitle:
            "Allow this app to intercept Magic Keyboard media keys to synchronize volume with AMBEO."
        ) {
          Toggle("", isOn: $model.settings.mediaKeyEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        LabeledDescription(
          title: "Atmos Boost",
          subtitle:
            "Volume offset automatically applied when switching between Dolby Atmos and stereo playback."
        ) {
          HStack {
            Slider(value: $model.settings.atmosBoostAmount, in: 0...40, step: 1)
              .frame(width: 150)
            Text("\(Int(model.settings.atmosBoostAmount))%")
              .monospacedDigit()
              .frame(width: 45, alignment: .trailing)
          }
        }
      } header: {
        Text("Preferences")
      }

      // --- Section 4: Shortcuts ---
      Section {
        LabeledDescription(
          title: "AMBEO 3D Mode",
          subtitle: "Toggle AMBEO 3D sound processing On or Off."
        ) {
          KeyboardShortcuts.Recorder(for: .toggleAmbeoMode)
        }

        LabeledDescription(
          title: "AMBEO 3D Level",
          subtitle: "Cycle through Light, Standard, and Boost intensity levels."
        ) {
          KeyboardShortcuts.Recorder(for: .cycleAmbeoLevel)
        }

        LabeledDescription(
          title: "Audio Preset",
          subtitle: "Cycle through Adaptive, Music, Movie, News, Neutral, and Sports."
        ) {
          KeyboardShortcuts.Recorder(for: .cyclePreset)
        }

        LabeledDescription(
          title: "Night Mode",
          subtitle: "Toggle dynamic range compression for late-night listening."
        ) {
          KeyboardShortcuts.Recorder(for: .toggleNightMode)
        }

        LabeledDescription(
          title: "Voice Enhancement",
          subtitle: "Toggle dialogue clarity enhancement."
        ) {
          KeyboardShortcuts.Recorder(for: .toggleVoiceEnhancement)
        }
      } header: {
        Text("Shortcuts")
      }

      // --- Footer: Version ---
      Section {
        HStack {
          Spacer()
          let version =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.3"
          Text("Ambeo Companion v\(version)")
            .font(.footnote)
            .foregroundStyle(.tertiary)
          Spacer()
        }
      }
      .listRowBackground(Color.clear)
    }
    .formStyle(.grouped)
    .onAppear {
      availableAudioDevices = AudioDeviceMonitor.shared.allOutputDevices
      refreshFormats(
        for: appModel.settings.audioDeviceUid,
        current: appModel.settings.fallbackAudioFormatID
      )
    }
  }

  // MARK: - Helpers

  private func refreshFormats(for deviceUID: String, current currentID: String) {
    guard let device = availableAudioDevices.first(where: { $0.uid == deviceUID }) else {
      supportedFormats = []
      return
    }
    supportedFormats = AudioDeviceMonitor.shared.supportedFormats(for: device.id)

    // Auto-select best 2ch format near 48 kHz if current selection is gone
    guard currentID.isEmpty || !supportedFormats.contains(where: { $0.id == currentID }) else {
      return
    }
    let best =
      supportedFormats
      .filter { $0.channels == 2 }
      .sorted {
        if $0.sampleRate != $1.sampleRate { return $0.distanceFrom48kHz < $1.distanceFrom48kHz }
        return $0.bitDepth > $1.bitDepth
      }.first
    if let id = best?.id {
      appModel.settings.fallbackAudioFormatID = id
    }
  }

  private func applyFallbackNow(formatID: String, deviceUID: String) {
    guard
      let device = availableAudioDevices.first(where: { $0.uid == deviceUID }),
      let format = supportedFormats.first(where: { $0.id == formatID })
    else { return }
    AudioDeviceMonitor.shared.fallback(format: format, for: device.id)
  }
}

// MARK: - Reusable label+description row

private struct LabeledDescription<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: Content

  var body: some View {
    LabeledContent {
      content
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
