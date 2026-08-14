import Foundation

/// Pure, `Sendable` codec between a `BackupStoreDTO` and the on-disk `Data`.
///
/// No SwiftData, no UI, no file I/O — just encode/decode + optional
/// encryption, so the whole round-trip is unit-testable in isolation. The
/// `@MainActor` `BackupStore` builds the DTO from live models and applies it;
/// this type only turns that DTO into bytes and back.
struct BackupService: Sendable {
    /// Encode a store snapshot to file bytes. A non-empty `passphrase` produces
    /// an encrypted envelope; otherwise the store is embedded as readable JSON.
    func makeFile(store: BackupStoreDTO, passphrase: String?) throws -> Data {
        let encoder = BackupCoding.encoder()
        if let passphrase, !passphrase.isEmpty {
            guard passphrase.count >= BackupCrypto.minPassphraseLength else {
                throw BackupError.validationFailed(
                    reason: "Passphrase must be at least \(BackupCrypto.minPassphraseLength) characters"
                )
            }
            let inner = try encoder.encode(store)
            let payload = try BackupCrypto.seal(inner, passphrase: passphrase)
            return try encoder.encode(BackupFile(encrypted: true, store: nil, crypto: payload))
        }
        return try encoder.encode(BackupFile(encrypted: false, store: store, crypto: nil))
    }

    /// Decode + validate file bytes back into a store snapshot. `passphrase` is
    /// required (and used) only for encrypted files.
    func readFile(_ data: Data, passphrase: String?) throws -> BackupStoreDTO {
        let decoder = BackupCoding.decoder()

        let file: BackupFile
        do { file = try decoder.decode(BackupFile.self, from: data) }
        catch { throw BackupError.corruptPayload }

        guard file.format == 1 else {
            throw BackupError.unsupportedFormat(found: file.format, supported: 1)
        }

        let store: BackupStoreDTO
        if file.encrypted {
            guard let payload = file.crypto else { throw BackupError.corruptPayload }
            guard let passphrase, !passphrase.isEmpty else { throw BackupError.missingPassphrase }
            let inner = try BackupCrypto.open(payload, passphrase: passphrase)
            do { store = try decoder.decode(BackupStoreDTO.self, from: inner) }
            catch { throw BackupError.corruptPayload }
        } else {
            guard let embedded = file.store else { throw BackupError.corruptPayload }
            store = embedded
        }

        try BackupValidator.validate(store)
        return store
    }

    /// Whether a file is encrypted, without needing a passphrase — lets the UI
    /// prompt for a passphrase only when one is actually required.
    func isEncrypted(_ data: Data) -> Bool {
        (try? BackupCoding.decoder().decode(BackupFile.self, from: data))?.encrypted ?? false
    }
}
