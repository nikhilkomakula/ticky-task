import SwiftUI
import SwiftData
import AppKit

/// Settings › Data: choose where the store is kept (with automatic data move),
/// and export/import backups. Restore is replace-all, gated behind a diff
/// preview and an explicit confirmation.
struct DataSettingsView: View {
    @State private var coordinator: BackupCoordinator
    @AppStorage(ModelContainerProvider.Keys.desired) private var desiredPath = ""
    @AppStorage(ModelContainerProvider.Keys.active) private var activePath = ""
    @State private var showRelaunchAlert = false
    @State private var relaunchFailed = false

    init(context: ModelContext) {
        _coordinator = State(initialValue: BackupCoordinator(context: context))
    }

    var body: some View {
        @Bindable var coordinator = coordinator
        Form {
            Section("Data Location") {
                LabeledContent("Current folder") {
                    Text(displayPath(currentDirPath))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if hasPendingChange {
                    Label("After relaunch, your data moves to: \(displayPath(effectiveDesiredPath))",
                          systemImage: "arrow.right.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button { chooseFolder() } label: { Label("Change Folder…", systemImage: "folder") }
                    Button { revealInFinder() } label: { Label("Reveal in Finder", systemImage: "magnifyingglass") }
                    if isCustomLocation {
                        Button(role: .destructive) { resetToDefault() } label: {
                            Label("Reset to Default", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
                Label("Tip: you can keep your data in an iCloud Drive, Google Drive, or Dropbox folder to carry it between Macs. It's a live database, not real-time sync — use one Mac at a time, and fully quit TickyTask and let the folder finish syncing before opening it on another Mac. Changing the folder moves your data there and relaunches TickyTask.",
                      systemImage: "cloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if relaunchFailed {
                    Label("Couldn't relaunch automatically — quit and reopen TickyTask to finish moving your data.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Export") {
                Toggle("Encrypt with a passphrase", isOn: $coordinator.encryptExport)
                if coordinator.encryptExport {
                    SecureField("Passphrase", text: $coordinator.passphrase)
                    SecureField("Confirm passphrase", text: $coordinator.passphraseConfirm)
                    Label("At least \(BackupCrypto.minPassphraseLength) characters. If you lose this passphrase, the backup cannot be recovered.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button {
                    coordinator.prepareExport()
                } label: {
                    Label("Export Backup…", systemImage: "square.and.arrow.up")
                }
                .disabled(!coordinator.canExport)
            }

            Section("Import") {
                Button {
                    coordinator.showImporter = true
                } label: {
                    Label("Import Backup…", systemImage: "square.and.arrow.down")
                }
                Text("Restoring replaces all current tasks, lists, tags, and occurrences with the backup's contents, and applies the backup's app settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let status = coordinator.statusMessage {
                Label(status, systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            if let error = coordinator.errorMessage {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .fileExporter(
            isPresented: $coordinator.showExporter,
            document: coordinator.exportDocument,
            contentType: .tickyTaskBackup,
            defaultFilename: coordinator.defaultFilename
        ) { coordinator.handleExport($0) }
        .fileImporter(
            isPresented: $coordinator.showImporter,
            allowedContentTypes: [.tickyTaskBackup, .json],
            allowsMultipleSelection: false
        ) { coordinator.handleImportPick($0) }
        .sheet(isPresented: $coordinator.showImportPassphrasePrompt) {
            ImportPassphraseSheet(coordinator: coordinator)
        }
        .sheet(isPresented: $coordinator.showRestoreConfirm) {
            RestoreConfirmSheet(coordinator: coordinator)
        }
        .alert("Relaunch to move your data?", isPresented: $showRelaunchAlert) {
            Button("Relaunch Now") { if !AppRelaunch.now() { relaunchFailed = true } }
            Button("Later", role: .cancel) {}
        } message: {
            Text("TickyTask will move all your data to the new folder and relaunch. Your tasks are preserved.")
        }
    }

    // MARK: - Data location

    private var defaultDirPath: String { (try? ModelContainerProvider.defaultDirectory().path) ?? "" }
    private var currentDirPath: String { activePath.isEmpty ? defaultDirPath : activePath }
    private var effectiveDesiredPath: String { desiredPath.isEmpty ? defaultDirPath : desiredPath }
    private var isCustomLocation: Bool { !desiredPath.isEmpty && !samePath(desiredPath, defaultDirPath) }
    private var hasPendingChange: Bool { !samePath(effectiveDesiredPath, currentDirPath) }

    private func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL == URL(fileURLWithPath: b).standardizedFileURL
    }

    private func displayPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to store your TickyTask data."
        if panel.runModal() == .OK, let url = panel.url {
            desiredPath = url.path
            if hasPendingChange { showRelaunchAlert = true }
        }
    }

    private func resetToDefault() {
        desiredPath = ""
        if hasPendingChange { showRelaunchAlert = true }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentDirPath)])
    }
}

/// Relaunches the app so a pending data-folder move can be applied at the next
/// launch (the store is relocated before it's opened).
private enum AppRelaunch {
    /// Wait for this instance to fully exit — releasing the store — then relaunch,
    /// so two instances never touch the store at once. Returns false if the helper
    /// couldn't be started; the caller then stays open rather than quitting into
    /// nothing (the pending data move still applies on the next manual launch).
    @discardableResult
    static func now() -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \(quoted(Bundle.main.bundlePath))"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        do {
            try task.run()
        } catch {
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct ImportPassphraseSheet: View {
    @Bindable var coordinator: BackupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Encrypted backup", systemImage: "lock.doc").font(.title3.weight(.semibold))
            Text("Enter the passphrase used when this backup was exported.")
                .foregroundStyle(.secondary)
            SecureField("Passphrase", text: $coordinator.importPassphrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit { coordinator.submitImportPassphrase() }
            if let error = coordinator.errorMessage {
                Label(error, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { coordinator.cancelImport() }
                Spacer()
                Button("Continue") { coordinator.submitImportPassphrase() }
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinator.importPassphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct RestoreConfirmSheet: View {
    @Bindable var coordinator: BackupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Replace all TickyTask data?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
            Text("This deletes everything currently in TickyTask and restores the selected backup. This can't be undone.")
                .foregroundStyle(.secondary)

            if let diff = coordinator.diff {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow { Text("Restored").bold(); Text("\(diff.totalAdded + diff.totalUpdated)") }
                    GridRow { Text("Removed").bold(); Text("\(diff.totalRemoved)").foregroundStyle(diff.totalRemoved > 0 ? .red : .primary) }
                }
                .font(.callout.monospacedDigit())
                .padding(.vertical, 4)
            }

            HStack {
                Button("Cancel", role: .cancel) { coordinator.cancelRestore() }
                Spacer()
                Button("Replace All Data", role: .destructive) { coordinator.confirmRestore() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(coordinator.isWorking)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
