import Foundation
import SwiftData

/// The app's SwiftData schema — the full set of persistent models.
///
/// We rely on SwiftData's **automatic lightweight migration** rather than a
/// hand-maintained `VersionedSchema` / `SchemaMigrationPlan`. Every model type is
/// shared across "versions," so multiple explicit `VersionedSchema`s would all
/// compute the *same* checksum and trip SwiftData's "Duplicate version checksums
/// detected" during staged migration. Automatic lightweight migration upgrades an
/// older on-disk store in place instead: it adds new columns with their defaults
/// and applies property renames declared on the models with
/// `@Attribute(originalName:)` — e.g. `TaskItem.isCritical` (formerly
/// `needsImmediateAttention`) — preserving all existing data.
enum AppSchema {
    static let models: [any PersistentModel.Type] =
        [TaskItem.self, Subtask.self, CustomList.self, TaskTag.self, TaskOccurrence.self]

    static let schema = Schema(models)
}
