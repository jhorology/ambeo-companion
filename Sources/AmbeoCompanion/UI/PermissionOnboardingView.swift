import SwiftUI

struct PermissionOnboardingView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("Set Up Permissions", systemImage: "lock.shield")
        .font(.title2.bold())
      Text(
        "Allow these permissions to control your AMBEO volume with media keys and enable Stealth Rewind with Apple Music."
      )
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
        Button(!appModel.needsPermissionOnboarding ? "Continue" : "Set Up Later") {
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
            Text(permission.title)
              .font(.body.weight(.medium))
            Spacer()
            Label(
              appModel.mediaKeyPermissions.statusLabel(for: permission),
              systemImage: appModel.mediaKeyPermissions.statusSymbol(for: permission)
            )
            .font(.caption)
            .foregroundStyle(granted ? Color.green : Color.secondary)
          }
          HStack(alignment: .center, spacing: 16) {
            Text(permission.explanation)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(appModel.mediaKeyPermissions.actionTitle(for: permission)) {
              permission.requestAndOpenSettings {
                await appModel.refreshMediaKeyPermissions()
              }
            }
          }
        }
      }
    }
  }
}
