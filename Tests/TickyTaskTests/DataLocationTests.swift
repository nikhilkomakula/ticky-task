import Testing
import Foundation
@testable import TickyTask

/// Covers the pure filesystem move behind the Settings "Data Location" feature.
/// Directory resolution and relaunch are exercised manually (they touch
/// UserDefaults / AppKit); this locks down the data-preserving move.
@Suite("Data location relocation")
struct DataLocationTests {
    private func makeDirs() throws -> (root: URL, source: URL, target: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ticky-reloc-" + UUID().uuidString)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        return (root, source, target)
    }

    @Test("Relocating moves the store and its sidecars, preserving contents")
    func movesStoreAndSidecars() throws {
        let fm = FileManager.default
        let (root, source, target) = try makeDirs()
        defer { try? fm.removeItem(at: root) }

        let name = ModelContainerProvider.storeFileName
        try "DB".write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try "WAL".write(to: source.appendingPathComponent(name + "-wal"), atomically: true, encoding: .utf8)
        try "SHM".write(to: source.appendingPathComponent(name + "-shm"), atomically: true, encoding: .utf8)

        try ModelContainerProvider.relocateStore(from: source, to: target, fileManager: fm)

        // Every file now lives in the target with its contents intact…
        #expect(try String(contentsOf: target.appendingPathComponent(name), encoding: .utf8) == "DB")
        #expect(try String(contentsOf: target.appendingPathComponent(name + "-wal"), encoding: .utf8) == "WAL")
        #expect(fm.fileExists(atPath: target.appendingPathComponent(name + "-shm").path))
        // …and the originals are gone.
        #expect(!fm.fileExists(atPath: source.appendingPathComponent(name).path))
        #expect(!fm.fileExists(atPath: source.appendingPathComponent(name + "-wal").path))
    }

    @Test("Relocating overwrites a stale store already at the target")
    func overwritesStaleTarget() throws {
        let fm = FileManager.default
        let (root, source, target) = try makeDirs()
        defer { try? fm.removeItem(at: root) }

        let name = ModelContainerProvider.storeFileName
        try "fresh".write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try "stale".write(to: target.appendingPathComponent(name), atomically: true, encoding: .utf8)

        try ModelContainerProvider.relocateStore(from: source, to: target, fileManager: fm)

        #expect(try String(contentsOf: target.appendingPathComponent(name), encoding: .utf8) == "fresh")
    }

    @Test("Relocating is a no-op when the source has no store")
    func noopWhenSourceEmpty() throws {
        let fm = FileManager.default
        let (root, source, target) = try makeDirs()
        defer { try? fm.removeItem(at: root) }

        try ModelContainerProvider.relocateStore(from: source, to: target, fileManager: fm)

        let entries = (try? fm.contentsOfDirectory(atPath: target.path)) ?? ["unexpected"]
        #expect(entries.isEmpty)
    }

    @Test("Relocating clears a stale sidecar left at the destination")
    func clearsStaleDestinationSidecar() throws {
        let fm = FileManager.default
        let (root, source, target) = try makeDirs()
        defer { try? fm.removeItem(at: root) }

        let name = ModelContainerProvider.storeFileName
        try "fresh".write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
        // Destination has a stale -wal but no main store; the source has no -wal.
        try "stale-wal".write(to: target.appendingPathComponent(name + "-wal"), atomically: true, encoding: .utf8)

        try ModelContainerProvider.relocateStore(from: source, to: target, fileManager: fm)

        #expect(try String(contentsOf: target.appendingPathComponent(name), encoding: .utf8) == "fresh")
        #expect(!fm.fileExists(atPath: target.appendingPathComponent(name + "-wal").path))   // stale sidecar removed
    }
}
