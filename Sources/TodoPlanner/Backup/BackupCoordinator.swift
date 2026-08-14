import Foundation
import SwiftData
import SwiftUI

/// View model for the Data settings tab: owns the export/import flow state and
/// maps `BackupError` to human-readable messages. All work is main-actor bound
/// because it reads and mutates the `ModelContext`.
@MainActor
@Observable
final class BackupCoordinator {
    // Export inputs
    var encryptExport = false
    var passphrase = ""
    var passphraseConfirm = ""

    // Import inputs
    var importPassphrase = ""

    // Presentation flags
    var showExporter = false
    var showImporter = false
    var showImportPassphrasePrompt = false
    var showRestoreConfirm = false
    var isWorking = false

    // Transient state
    var exportDocument = BackupDocument()
    var diff: BackupDiff?
    var statusMessage: String?
    var errorMessage: String?

    private var pendingStore: BackupStoreDTO?
    private var pendingImportData: Data?

    private let context: ModelContext
    private let service = BackupService()

    init(context: ModelContext) { self.context = context }

    var canExport: Bool {
        guard encryptExport else { return true }
        return passphrase.count >= BackupCrypto.minPassphraseLength && passphrase == passphraseConfirm
    }

    var defaultFilename: String {
        "TodoPlanner Backup \(Self.dateStamp.string(from: Date()))"
    }

    // MARK: Export

    func prepareExport() {
        clearMessages()
        do {
            let data = try BackupStore.exportData(context: context,
                                                   passphrase: encryptExport ? passphrase : nil)
            exportDocument = BackupDocument(data: data)
            showExporter = true
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func handleExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            statusMessage = "Backup exported."
            passphrase = ""
            passphraseConfirm = ""
        case .failure(let error):
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Import

    func handleImportPick(_ result: Result<[URL], Error>) {
        clearMessages()
        switch result {
        case .failure(let error):
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let data = try readFile(at: url)
                pendingImportData = data
                if service.isEncrypted(data) {
                    importPassphrase = ""
                    showImportPassphrasePrompt = true
                } else {
                    try decodeAndPreview(data: data, passphrase: nil)
                }
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    func submitImportPassphrase() {
        guard let data = pendingImportData else { return }
        do {
            try decodeAndPreview(data: data, passphrase: importPassphrase)
            errorMessage = nil
            showImportPassphrasePrompt = false
        } catch {
            // Keep the prompt open so the user can retry the passphrase.
            errorMessage = Self.message(for: error)
        }
    }

    func cancelImport() {
        showImportPassphrasePrompt = false
        clearPending()
    }

    func confirmRestore() {
        guard let store = pendingStore else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try BackupStore.restore(store, context: context)
            // Restored `alarmEnabled` tasks have no live notification requests
            // until we reconcile them against the rebuilt store.
            Task { await NotificationService.syncTaskReminders(context: context) }
            statusMessage = "Backup restored."
            showRestoreConfirm = false
            clearPending()
        } catch {
            errorMessage = Self.message(for: error)
            showRestoreConfirm = false
            clearPending()
        }
    }

    func cancelRestore() {
        showRestoreConfirm = false
        clearPending()
    }

    // MARK: Private

    private func decodeAndPreview(data: Data, passphrase: String?) throws {
        let store = try service.readFile(data, passphrase: passphrase)
        pendingStore = store
        diff = try BackupStore.preview(store, context: context)
        showRestoreConfirm = true
    }

    /// Backups are tiny (tasks are text); cap the read so an enormous picked
    /// file can't freeze the UI or exhaust memory before we even decode.
    static let maxImportBytes = 50 * 1024 * 1024

    /// Fail-closed size check: an unknown size (metadata lookup failed) is
    /// treated as over-limit so we never fall through to an unbounded read.
    nonisolated static func exceedsSizeLimit(_ size: Int?) -> Bool {
        guard let size else { return true }
        return size > maxImportBytes
    }

    private func readFile(at url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard !Self.exceedsSizeLimit(size) else {
            throw BackupError.fileTooLarge(maxMB: Self.maxImportBytes / (1024 * 1024))
        }
        return try Data(contentsOf: url)
    }

    private func clearPending() {
        pendingStore = nil
        pendingImportData = nil
        diff = nil
        importPassphrase = ""
    }

    private func clearMessages() {
        statusMessage = nil
        errorMessage = nil
    }

    private func isCancellation(_ error: Error) -> Bool {
        (error as? CocoaError)?.code == .userCancelled
    }

    static func message(for error: Error) -> String {
        switch error {
        case BackupError.wrongPassphrase:
            return "Wrong passphrase, or the backup has been altered."
        case BackupError.missingPassphrase:
            return "This backup is encrypted — enter its passphrase."
        case BackupError.corruptPayload:
            return "This file isn't a valid TodoPlanner backup."
        case BackupError.fileTooLarge(let maxMB):
            return "That file is too large to be a TodoPlanner backup (over \(maxMB) MB)."
        case BackupError.unsupportedFormat(let found, _), BackupError.unsupportedSchema(let found, _):
            return "This backup was made by a newer version of TodoPlanner (v\(found)). Update the app to restore it."
        case BackupError.validationFailed(let reason):
            return "The backup didn't pass validation: \(reason)."
        case BackupError.invalidReference(let entity, _):
            return "The backup references a \(entity) that's missing from the file."
        default:
            return error.localizedDescription
        }
    }

    private static let dateStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
