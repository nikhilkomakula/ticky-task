import Foundation
import SwiftData

/// Builds the app's SwiftData `ModelContainer`.
///
/// The store is a local, on-disk SQLite database that lives in a user-choosable
/// data directory (Settings › Data), defaulting to
/// `~/Library/Application Support/TickyTask/`. Schema upgrades use SwiftData's
/// automatic lightweight migration (see `AppSchema`). Kept behind this provider
/// so tests and previews can swap in an in-memory store.
enum ModelContainerProvider {
    /// The store's file name inside whichever directory holds the data.
    static let storeFileName = "TickyTask.store"
    /// SQLite sidecar suffixes that must travel with the store when it moves.
    private static let storeSuffixes = ["", "-wal", "-shm"]

    /// UserDefaults keys for the data location. `desired` is the folder the user
    /// picked in Settings (`""` = the default location); `active` records where
    /// the store physically lives right now (managed by this provider).
    enum Keys {
        static let desired = "desiredDataDirectory"
        static let active  = "activeDataDirectory"
    }

    /// The production on-disk container. Relocates the store first if the user
    /// changed the data folder, then opens it. Throws so the app can present a
    /// recovery UI (`StoreErrorView`) instead of crashing.
    static func makeContainer() throws -> ModelContainer {
        let url = try resolveStoreURL()
        let configuration = ModelConfiguration(schema: AppSchema.schema, url: url)
        return try ModelContainer(for: AppSchema.schema, configurations: configuration)
    }

    /// An ephemeral in-memory container for tests and SwiftUI previews.
    static func makeInMemoryContainer() -> ModelContainer {
        let configuration = ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: AppSchema.schema, configurations: configuration)
        } catch {
            fatalError("Failed to create in-memory ModelContainer: \(error)")
        }
    }

    // MARK: - Data directory

    /// Default data directory: `~/Library/Application Support/TickyTask/`.
    static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return base.appendingPathComponent("TickyTask", isDirectory: true)
    }

    /// Default store URL inside the default directory (used by callers/tests).
    static func defaultStoreURL() throws -> URL {
        try defaultDirectory().appendingPathComponent(storeFileName)
    }

    /// The folder the user chose in Settings, or `nil` for the default.
    static func desiredDirectory() -> URL? {
        let path = UserDefaults.standard.string(forKey: Keys.desired) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The directory where the store currently physically lives.
    static func currentDirectory() -> URL {
        if let path = UserDefaults.standard.string(forKey: Keys.active), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return (try? defaultDirectory()) ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Record the user's chosen directory (`nil` = default). Takes effect on the
    /// next launch, when the store — not yet open — is relocated.
    static func setDesiredDirectory(_ url: URL?) {
        UserDefaults.standard.set(url?.path ?? "", forKey: Keys.desired)
    }

    /// Resolve the store URL for this launch, first moving the store to the user's
    /// chosen directory if it changed. Relocation happens here, before the
    /// container opens, so an open store is never moved.
    private static func resolveStoreURL() throws -> URL {
        let fm = FileManager.default
        let target = try (desiredDirectory() ?? defaultDirectory())
        let current = currentDirectory()

        // No folder change: open the store where it already lives.
        guard target.standardizedFileURL != current.standardizedFileURL else {
            UserDefaults.standard.set(target.path, forKey: Keys.active)
            return target.appendingPathComponent(storeFileName)
        }

        // The user chose a new folder. Adopt/move safely; on ANY failure keep the
        // data exactly where it is (when that store is intact) rather than opening a
        // blank or half-moved store.
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let targetStore = target.appendingPathComponent(storeFileName)

            if fm.fileExists(atPath: targetStore.path) {
                // The destination already holds a store (e.g. an iCloud/Drive folder
                // populated by another Mac). ADOPT it — never overwrite — and leave
                // the source untouched at its old location.
                UserDefaults.standard.set(target.path, forKey: Keys.active)
                return targetStore
            }

            if fm.fileExists(atPath: current.appendingPathComponent(storeFileName).path) {
                // Move this Mac's store into the (empty) destination.
                try relocateStore(from: current, to: target, fileManager: fm)
                UserDefaults.standard.set(target.path, forKey: Keys.active)
                return targetStore
            }

            // Neither side has a store.
            if isExplicitlyChosen(current) {
                // `active` pointed at a real prior location whose store is now missing
                // (e.g. an unmounted volume). Don't strand the data behind a fresh
                // blank store — fail loudly and leave the preferences intact.
                throw CocoaError(.fileNoSuchFile)
            }
            // True first run: create a fresh store at the target.
            UserDefaults.standard.set(target.path, forKey: Keys.active)
            return targetStore
        } catch {
            // Fall back to the current location only when its store is intact, and
            // keep the preferences pointing there so Settings reflects reality. If the
            // current store is also gone, rethrow so the app shows the recovery UI
            // instead of silently starting empty.
            let currentStore = current.appendingPathComponent(storeFileName)
            if fm.fileExists(atPath: currentStore.path) {
                UserDefaults.standard.set(current.path, forKey: Keys.desired)
                UserDefaults.standard.set(current.path, forKey: Keys.active)
                return currentStore
            }
            throw error
        }
    }

    /// Whether `dir` is the directory the user explicitly chose (recorded as the
    /// active location), rather than the default first-run location.
    private static func isExplicitlyChosen(_ dir: URL) -> Bool {
        guard let active = UserDefaults.standard.string(forKey: Keys.active), !active.isEmpty else { return false }
        return URL(fileURLWithPath: active, isDirectory: true).standardizedFileURL == dir.standardizedFileURL
    }

    /// Move the store and its SQLite sidecars between directories. Copies every
    /// file to the target first (so a failure leaves the source intact), then
    /// removes the originals. No-op on a fresh install (nothing to move).
    static func relocateStore(from source: URL, to target: URL, fileManager fm: FileManager) throws {
        guard fm.fileExists(atPath: source.appendingPathComponent(storeFileName).path) else { return }

        // Stage every source component under a unique temp name first, then promote
        // the whole set into place. A failure mid-copy therefore leaves only temp
        // files (cleaned up) — never a partial, adoptable `TickyTask.store` — and the
        // source is untouched.
        let stageSuffix = ".migrating-\(UUID().uuidString)"
        var staged: [(temp: URL, final: URL)] = []
        do {
            for suffix in storeSuffixes {
                let src = source.appendingPathComponent(storeFileName + suffix)
                guard fm.fileExists(atPath: src.path) else { continue }
                let final = target.appendingPathComponent(storeFileName + suffix)
                let temp = target.appendingPathComponent(storeFileName + suffix + stageSuffix)
                if fm.fileExists(atPath: temp.path) { try fm.removeItem(at: temp) }
                try fm.copyItem(at: src, to: temp)
                staged.append((temp, final))
            }
            // All copies succeeded: clear any existing/stale destination components
            // (so no mismatched `-wal`/`-shm` survives), then promote the staged set
            // with per-file atomic renames.
            for suffix in storeSuffixes {
                let final = target.appendingPathComponent(storeFileName + suffix)
                if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            }
            for item in staged { try fm.moveItem(at: item.temp, to: item.final) }
        } catch {
            for item in staged { try? fm.removeItem(at: item.temp) }   // no adoptable partial store
            throw error
        }
        // Destination is complete — remove the originals (best-effort; a lingering
        // source copy is benign, never data loss).
        for suffix in storeSuffixes {
            let src = source.appendingPathComponent(storeFileName + suffix)
            if fm.fileExists(atPath: src.path) { try? fm.removeItem(at: src) }
        }
    }
}
