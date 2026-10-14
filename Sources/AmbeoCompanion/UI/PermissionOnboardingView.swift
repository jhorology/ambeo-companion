import SwiftUI

struct PermissionOnboardingView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("Set Up Media Keys", systemImage: "keyboard")
        .font(.title2.bold())
      Text("Allow these two permissions to control your AMBEO volume with your Mac's media keys.")
        .foregroundStyle(.secondary)
      PermissionSettingsView()
      Text(
        "In System Settings > Privacy & Security, enable Ambeo Companion. If it is missing, use + to add this app from \(Bundle.main.bundlePath)."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      Text(
        "If macOS asks you to quit and reopen the app, do so. After rebuilding, an enabled switch may need to be turned off and on again."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      HStack {
        Button("Check Again") {
          Task { await appModel.refreshMediaKeyPermissions() }
        }
        Spacer()
        Button(appModel.mediaKeyPermissions.allGranted ? "Continue" : "Set Up Later") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 510)
  }
}

struct PermissionSettingsView: View {
  @Environment(AppModel.self) private var appModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(MediaKeyPermission.allCases) { permission in
        let granted = appModel.mediaKeyPermissions.isGranted(permission)
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Label(
              granted ? "Allowed" : "Permission Needed",
              systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .font(.caption)
            .foregroundStyle(granted ? Color.green : Color.secondary)
            Spacer()
            Button("Open Settings") { permission.requestAndOpenSettings() }
          }
          Text(permission.title).font(.headline)
          Text(permission.explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
