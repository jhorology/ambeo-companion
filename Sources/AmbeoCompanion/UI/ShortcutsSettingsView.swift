import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    @Bindable var model = appModel

    VStack(spacing: 0) {
      Form {
        // --- Section 1: Volume & Media Keys ---
        Section {
          LabeledDescription(
            title: "Media Key Interception",
            subtitle:
              "Allow this app to intercept Magic Keyboard media keys to synchronize volume with AMBEO. Turn off to assign custom volume and mute shortcuts."
          ) {
            Toggle("", isOn: $model.settings.mediaKeyEnabled).labelsHidden().toggleStyle(.switch)
          }

          if !model.settings.mediaKeyEnabled {
            LabeledDescription(title: "Volume Up", subtitle: "Increase soundbar volume.") {
              KeyboardShortcuts.Recorder(for: .volumeUp)
            }

            LabeledDescription(title: "Volume Down", subtitle: "Decrease soundbar volume.") {
              KeyboardShortcuts.Recorder(for: .volumeDown)
            }

            LabeledDescription(title: "Mute", subtitle: "Toggle soundbar mute On or Off.") {
              KeyboardShortcuts.Recorder(for: .toggleMute)
            }
          }
        } header: {
          Text("Volume & Media Keys")
        }

        // --- Section 2: Soundbar & Audio ---
        Section {
          LabeledDescription(
            title: "Wake Up Soundbar",
            subtitle: "Wake up the soundbar and reconnect HDMI TV audio when in standby."
          ) { KeyboardShortcuts.Recorder(for: .wakeUpSoundbar) }

          LabeledDescription(
            title: "AMBEO 3D Mode",
            subtitle: "Toggle AMBEO 3D sound processing On or Off."
          ) { KeyboardShortcuts.Recorder(for: .toggleAmbeoMode) }

          LabeledDescription(
            title: "AMBEO 3D Level",
            subtitle: "Cycle through Light, Standard, and Boost intensity levels."
          ) { KeyboardShortcuts.Recorder(for: .cycleAmbeoLevel) }

          LabeledDescription(
            title: "Audio Preset",
            subtitle: "Cycle through Adaptive, Music, Movie, News, Neutral, and Sports."
          ) { KeyboardShortcuts.Recorder(for: .cyclePreset) }

          LabeledDescription(
            title: "Night Mode",
            subtitle: "Toggle dynamic range compression for late-night listening."
          ) { KeyboardShortcuts.Recorder(for: .toggleNightMode) }

          LabeledDescription(
            title: "Voice Enhancement",
            subtitle: "Toggle dialogue clarity enhancement."
          ) { KeyboardShortcuts.Recorder(for: .toggleVoiceEnhancement) }
        } header: {
          Text("Soundbar & Audio")
        }

        // --- Section 3: LED Brightness ---
        Section {
          LabeledDescription(
            title: "All LEDs",
            subtitle:
              "Cycle LED Bar, AMBEO Logo, and Codec LED together through Off, 25%, 50%, and 100%."
          ) { KeyboardShortcuts.Recorder(for: .cycleAllLedsBrightness) }

          LabeledDescription(
            title: "LED Bar",
            subtitle: "Cycle top LED bar brightness through Off, 25%, 50%, and 100%."
          ) { KeyboardShortcuts.Recorder(for: .cycleLedBarBrightness) }

          LabeledDescription(
            title: "AMBEO Logo",
            subtitle: "Cycle front AMBEO logo brightness through Off, 25%, 50%, and 100%."
          ) { KeyboardShortcuts.Recorder(for: .cycleAmbeoLogoBrightness) }

          LabeledDescription(
            title: "Codec LED",
            subtitle: "Cycle codec indicator LED brightness through Off, 25%, 50%, and 100%."
          ) { KeyboardShortcuts.Recorder(for: .cycleCodecLedBrightness) }
        } header: {
          Text("LED Brightness")
        }
      }.formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }.padding(.horizontal, 20).padding(.vertical, 12)
    }.frame(width: 450, height: 480)
  }
}
