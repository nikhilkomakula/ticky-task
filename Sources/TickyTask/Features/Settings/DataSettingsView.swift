import SwiftUI
import SwiftData

/// Settings › Data: export the whole store to a `.tickytask` backup file
/// (optionally passphrase-encrypted) and restore one. Restore is replace-all,
/// gated behind a diff preview and an explicit confirmation.
struct DataSettingsView: View {
    @State private var coordinator: BackupCoordinator

    init(context: ModelContext) {
        _coordinator = State(initialValue: BackupCoordinator(context: context))
    }

    var body: some View {
        @Bindable var coordinator = coordinator
        Form {
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
                Text("Restoring replaces all current tasks, lists, tags, and occurrences with the backup's contents.")
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
