import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Passphrase-based encryption for backups: PBKDF2-HMAC-SHA256 derives a
/// 256-bit key from the user's passphrase (with a random per-file salt), and
/// AES-256-GCM seals the JSON. The salt and iteration count travel in the file
/// so the same passphrase restores the backup on any machine — no Keychain
/// material is tied to the source Mac. The GCM tag authenticates the ciphertext:
/// tampering or a wrong passphrase both fail the `open` with an auth error.
enum BackupCrypto {
    /// OWASP-recommended floor for PBKDF2-HMAC-SHA256 (2023).
    static let defaultIterations = 600_000
    static let saltLength = 32
    static let keyLength = 32
    /// A passphrase shorter than this is rejected before sealing.
    static let minPassphraseLength = 12
    /// Accepted range for the iteration count. The count comes from the file on
    /// import, so it is untrusted: a negative value would trap the `UInt32`
    /// conversion and a huge one is a CPU denial-of-service before any auth.
    static let minIterations = 1
    static let maxIterations = 10_000_000

    static func randomSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        guard SecRandomCopyBytes(kSecRandomDefault, saltLength, &bytes) == errSecSuccess else {
            throw BackupError.corruptPayload
        }
        return Data(bytes)
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard (minIterations...maxIterations).contains(iterations) else {
            throw BackupError.corruptPayload
        }
        var derived = [UInt8](repeating: 0, count: keyLength)
        let pw = Array(passphrase.utf8)
        let status = salt.withUnsafeBytes { saltBuf -> Int32 in
            pw.withUnsafeBufferPointer { pwBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBuf.baseAddress, pw.count,
                    saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived, derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw BackupError.corruptPayload }
        return SymmetricKey(data: derived)
    }

    static func seal(_ plaintext: Data, passphrase: String,
                     iterations: Int = defaultIterations) throws -> EncryptedPayload {
        let salt = try randomSalt()
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return EncryptedPayload(salt: salt,
                                nonce: Data(sealed.nonce),
                                ciphertext: sealed.ciphertext,
                                tag: sealed.tag,
                                iterations: iterations)
    }

    static func open(_ payload: EncryptedPayload, passphrase: String) throws -> Data {
        guard payload.salt.count == saltLength else { throw BackupError.corruptPayload }
        guard (minIterations...maxIterations).contains(payload.iterations) else {
            throw BackupError.corruptPayload
        }
        do {
            let key = try deriveKey(passphrase: passphrase, salt: payload.salt, iterations: payload.iterations)
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: payload.nonce),
                                            ciphertext: payload.ciphertext,
                                            tag: payload.tag)
            return try AES.GCM.open(box, using: key)
        } catch let error as BackupError {
            throw error   // a malformed payload stays "corrupt", not "wrong passphrase"
        } catch {
            // AES-GCM cannot distinguish a wrong passphrase from tampering — both
            // fail the tag check. Surface a single, user-actionable error.
            throw BackupError.wrongPassphrase
        }
    }
}
