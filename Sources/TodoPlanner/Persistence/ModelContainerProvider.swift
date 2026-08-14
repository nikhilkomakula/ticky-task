import Foundation
import SwiftData

/// Builds the app's SwiftData `ModelContainer`.
///
/// Local-only, on-disk store — no CloudKit (sync was dropped in favor of manual
/// backup export/import). Kept behind this provider so tests and previews can
/// swap in an in-memory store.
enum ModelContainerProvider {
    /// The production on-disk container. Throws so the app can present a
    /// recovery UI (see `StoreErrorView`) instead of crashing on a migration
    /// failure, corrupt store, or unavailable filesystem.
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: try defaultStoreURL())
        return try ModelContainer(
            for: schema,
            migrationPlan: TodoPlannerMigrationPlan.self,
            configurations: configuration
        )
    }

    /// Dedicated on-disk location: `~/Library/Application Support/TodoPlanner/TodoPlanner.store`
    /// (namespaced rather than the generic `default.store` in the shared root).
    static func defaultStoreURL() throws -> URL {
        let fileManager = FileManager.default
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let directory = base.appendingPathComponent("TodoPlanner", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("TodoPlanner.store")
    }

    /// An ephemeral in-memory container for tests and SwiftUI previews.
    static func makeInMemoryContainer() -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Failed to create in-memory ModelContainer: \(error)")
        }
    }
}
