import Foundation
import SwiftData

/// Version 1 of the persistent schema.
///
/// When the model changes in a breaking way, add a new `VersionedSchema` and a
/// `MigrationStage` to `TickyTaskMigrationPlan` rather than mutating this one.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [TaskItem.self, Subtask.self, CustomList.self, TaskTag.self, TaskOccurrence.self]
    }
}

/// Migration plan for the SwiftData store. Empty for v1 (nothing to migrate yet).
enum TickyTaskMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
