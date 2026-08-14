import Foundation
import SwiftData

/// Version 1 of the persistent schema — the original v0.1.0 / v0.1.1 shape.
///
/// Do not mutate a shipped `VersionedSchema`. When the model changes, add a new
/// `VersionedSchema` and a `MigrationStage` to `TickyTaskMigrationPlan` (as
/// `SchemaV2` does below) rather than editing an existing version.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [TaskItem.self, Subtask.self, CustomList.self, TaskTag.self, TaskOccurrence.self]
    }
}

/// Version 2 (v0.1.2) adds `TaskItem.needsImmediateAttention` (a defaulted
/// `Bool`). The change is purely additive, so an existing v1 store migrates
/// forward **lightweight**: SwiftData adds the column with its default (`false`)
/// and preserves all data.
enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [TaskItem.self, Subtask.self, CustomList.self, TaskTag.self, TaskOccurrence.self]
    }
}

/// Migration plan for the SwiftData store: the ordered list of schema versions
/// and the stages between them.
enum TickyTaskMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)]
    }
}
