import SwiftUI
import AppKit

/// Settings › General: launch-at-login and software updates.
struct GeneralSettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true

    @State private var loginEnabled = LoginItemService.isEnabled
    @State private var isChecking = false
    @State private var checkOutcome: UpdateService.Outcome?
    @State private var checkError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open TickyTask at login", isOn: Binding(
                    get: { loginEnabled },
                    set: { newValue in
                        LoginItemService.setEnabled(newValue)
                        loginEnabled = LoginItemService.isEnabled   // reflect the real result
                    }
                ))
                Text("Launches TickyTask automatically when you log in. You can also manage this in System Settings › General › Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $autoCheckUpdates)
                Button(action: checkNow) {
                    HStack(spacing: 8) {
                        Text("Check for Updates…")
                        if isChecking { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isChecking)
                updateStatus
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { loginEnabled = LoginItemService.isEnabled }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginEnabled = LoginItemService.isEnabled   // reflect out-of-band changes from System Settings
        }
    }

    @ViewBuilder private var updateStatus: some View {
        if let checkError {
            Label(checkError, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
        } else if let outcome = checkOutcome {
            switch outcome {
            case .upToDate:
                Label("You're on the latest version.", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            case .noReleases:
                Label("No releases have been published yet.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .updateAvailable(let release):
                updateAvailableRow(release)
            }
        } else if let release = app.availableUpdate {
            updateAvailableRow(release)
        }
    }

    private func updateAvailableRow(_ release: AppRelease) -> some View {
        HStack(spacing: 8) {
            Label("Update available: \(release.version)", systemImage: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Link("View Release", destination: release.url).font(.caption)
        }
    }

    private func checkNow() {
        isChecking = true
        checkError = nil
        checkOutcome = nil
        Task { @MainActor in
            defer { isChecking = false }
            do {
                let outcome = try await UpdateService.check(currentVersion: Bundle.main.appVersion)
                checkOutcome = outcome
                if case .updateAvailable(let release) = outcome { app.availableUpdate = release }
            } catch {
                checkError = "Couldn't check for updates — \(error.localizedDescription)"
            }
        }
    }
}
