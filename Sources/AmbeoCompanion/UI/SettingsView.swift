import AmbeoCore
import SwiftUI

// A lightweight ViewModel to provide dynamic lists to the Settings UI
@MainActor
final class SettingsViewModel: ObservableObject {
  @Published var ambeoNetDevices: [AmbeoNetworkDevice] = []
  @Published var availableAudioDevices: [AudioDevice] = []
  @Published var supportedFormats: [AudioPhysicalFormat] = []

  init() { refreshDevices() }

  func refreshDevices() {
    availableAudioDevices = AudioDeviceMonitor.shared.allOutputDevices
  }

  func updateFormats(for deviceUID: String) {
    if let selectedDevice = availableAudioDevices.first(where: { $0.uid == deviceUID }) {
      supportedFormats = AudioDeviceMonitor.shared.supportedFormats(for: selectedDevice.id)
    }
  }

  func fallbackAudio(to formatID: String, for deviceUID: String) {
    guard let format = supportedFormats.first(where: { $0.id == formatID }) else { return }
    guard let device = availableAudioDevices.first(where: { $0.uid == deviceUID }) else { return }
    AudioDeviceMonitor.shared.fallback(format: format, for: device.id)
  }
}

struct SettingsView: View {
  @Environment(AmbeoAppModel.self) private var appModel
  @StateObject private var viewModel = SettingsViewModel()

  @AppStorage("AmbeoNetworkDeviceUID") private var ambeoNetDeviceUID: String = ""
  @AppStorage("TargetAudioDeviceUID") private var targetAudioDeviceUID: String = ""
  @AppStorage("FallbackAudioFormat") private var fallbackAudioFormat: String = ""
  @AppStorage("HookMediaKeys") private var hookMediaKeys: Bool = true
  @AppStorage("AtmosBoostAmount") private var atmosBoost: Double = 10

  var body: some View {
    Form {
      // --- Section 1: Network ---
      Section {
        LabeledDescription(
          title: "AMBEO Soundbar",
          subtitle: "Choose the AMBEO Soundbar to control over your local network."
        ) {
          Picker("", selection: $ambeoNetDeviceUID) {
            if ambeoNetDeviceUID.isEmpty {
              Text(appModel.discoveredDevices.isEmpty ? "Searching..." : "Select a device").tag("")
            }
            ForEach(appModel.discoveredDevices) { device in
              Text(device.name).tag(device.id)
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
            "Choose the physical connection device for your AMBEO soundbar. If it's connected via eARC, it may be a display device."
        ) {
          Picker("", selection: $targetAudioDeviceUID) {
            if targetAudioDeviceUID.isEmpty {
              Text("Select a device").tag("")
            }
            ForEach(viewModel.availableAudioDevices) { device in
              Text(device.name).tag(device.uid)
            }
          }
          .onChange(of: targetAudioDeviceUID) { _, newValue in
            updateDefaultFormat(for: newValue)
          }
          .labelsHidden()
        }

        LabeledDescription(
          title: "Fallback Format",
          subtitle:
            "The format used when Dolby Atmos passthrough is inactive to prevent macOS from defaulting to 192kHz."
        ) {
          Picker("", selection: $fallbackAudioFormat) {
            ForEach(viewModel.supportedFormats) { format in
              Text(format.displayName).tag(format.id)
            }
          }
          .disabled(viewModel.supportedFormats.isEmpty)
          .labelsHidden()
        }
        #if DEBUG
        LabeledDescription(title: "Fallback Test", subtitle: "") {
          Button("Execute", systemImage: "ladybug.circle") {
            viewModel.fallbackAudio(to: fallbackAudioFormat, for: targetAudioDeviceUID)
          }
          .disabled(fallbackAudioFormat.isEmpty || targetAudioDeviceUID.isEmpty)
        }
        #endif
      } header: {
        Text("Target Audio Device")
      }

      // --- Section 3: Behavior ---
      Section {
        LabeledDescription(
          title: "Media Key Interception",
          subtitle:
            "Allow this app to intercept Magic Keyboard media keys to synchronize volume with AMBEO."
        ) {
          Toggle("", isOn: $hookMediaKeys)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        LabeledDescription(
          title: "Atmos Boost",
          subtitle: "Adjust the relative volume boost applied during Dolby Atmos playback."
        ) {
          HStack {
            Slider(value: $atmosBoost, in: 0...30, step: 1)
              .frame(width: 150)
            Text("\(Int(atmosBoost)) dB")
              .monospacedDigit()
              .frame(width: 45, alignment: .trailing)
          }
        }
      } header: {
        Text("Preferences")
      }
    }
    .formStyle(.grouped)
    // .padding(0)
    // .frame(width: 480)
    .onAppear {
      updateDefaultFormat(for: targetAudioDeviceUID)
    }
    // ... (onAppear 類) ...
  }

  private func updateDefaultFormat(for uid: String) {
    viewModel.updateFormats(for: uid)
    if fallbackAudioFormat.isEmpty
      || !viewModel.supportedFormats.contains(where: { $0.id == fallbackAudioFormat })
    {
      let format = viewModel.supportedFormats
        .filter { $0.channels == 2 }
        .sorted { a, b in
          if a.sampleRate != b.sampleRate {
            return a.distanceFrom48kHz < b.distanceFrom48kHz
          }
          return a.bitDepth > b.bitDepth
        }.first
      fallbackAudioFormat = format?.id ?? ""
    }
  }

}

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
            // 💡 文字が切れないように「固定サイズを解除」するのが Mac アプリのコツ
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
