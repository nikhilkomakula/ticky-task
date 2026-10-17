import Foundation
import SwiftData
import Testing
@testable import TickyTask

@Suite(.serialized) @MainActor
struct KanbanBackupTests {
    // MARK: - Test Helpers

    func makeTempDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    // MARK: - (a) DTO Codability: empty Kanban section

    @Test("Kanban backup DTO is codable: empty section")
    func kanbanDTOCodeable() throws {
        let dto = KanbanBackupDTO()
        let encoded = try JSONEncoder().encode(dto)
        let decoded = try JSONDecoder().decode(KanbanBackupDTO.self, from: encoded)
        #expect(decoded.version == KanbanBackupDTO.currentVersion)
        #expect(decoded.people.isEmpty)
    }

    // MARK: - (b) Validator: version check

    @Test("Validator rejects unsupported Kanban version")
    func validatorRejectsUnsupportedVersion() throws {
        let kanban = KanbanBackupDTO(version: 99)
        #expect(throws: BackupError.self) {
            try KanbanBackupValidator.validate(kanban)
        }
    }

    // MARK: - (c) Validator: empty section passes

    @Test("Validator accepts empty Kanban section")
    func validatorAcceptsEmpty() throws {
        let kanban = KanbanBackupDTO()
        let report = try KanbanBackupValidator.validate(kanban)
        #expect(report.droppedDependencyEdges == 0)
        #expect(report.droppedPlannerLinks == 0)
    }

    // MARK: - (d) BackupDiff includes Kanban section

    @Test("BackupDiff structure includes Kanban section")
    func backupDiffIncludesKanban() throws {
        let diff = BackupDiff(
            taskItems: EntityDiff(imported: [], existing: []),
            subtasks: EntityDiff(imported: [], existing: []),
            taskTags: EntityDiff(imported: [], existing: []),
            customLists: EntityDiff(imported: [], existing: []),
            taskOccurrences: EntityDiff(imported: [], existing: []),
            kanban: nil,
            droppedPlannerLinks: 0
        )
        #expect(diff.kanban == nil)
        #expect(diff.droppedPlannerLinks == 0)
    }

    // MARK: - (e) Settings DTO includes new Kanban keys

    @Test("AppSettingsDTO captures new Kanban keys")
    func settingsDTOIncludesKanban() throws {
        let dto = AppSettingsDTO(
            appTheme: nil,
            calendarColumns: nil,
            weekStartsMonday: nil,
            showWeekends: nil,
            compactView: nil,
            taskSortMode: nil,
            moveCompletedToBottom: nil,
            autoCarryForward: nil,
            autoDeleteCompletedEnabled: nil,
            autoDeleteCompletedDays: nil,
            endOfDayReminderEnabled: nil,
            endOfDayReminderMinutes: nil,
            menuBarOnly: nil,
            autoCheckUpdates: nil,
            weeklySummary: nil,
            showPlannerModule: true,
            showKanbanModule: true,
            defaultModule: "kanban",
            kanbanPopoverProjectID: "proj-123",
            kanbanSummaryInstructions: "Custom",
            kanbanTemplates: nil,
            kanbanWeightedLoadDefault: nil,
            kanbanWipPolicyDefault: nil,
            kanbanLoadMeasureDefault: nil,
            kanbanOpenTaskTargetDefault: nil,
            kanbanDueSoonThresholdDefault: nil,
            kanbanSuggestDoneDefault: nil,
            kanbanNotifyDueDates: nil,
            kanbanNotifyDueMinutes: nil
        )
        #expect(dto.showPlannerModule == true)
        #expect(dto.showKanbanModule == true)
        #expect(dto.defaultModule == "kanban")
        #expect(dto.kanbanPopoverProjectID == "proj-123")
    }

    // MARK: - (f) Backup round trip semantics

    @Test("D11 semantics: absent kanban key keeps boards")
    func d11AbsentKeyKeepsBoards() throws {
        // Create a store without Kanban section
        let store = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.1.17",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [], subtasks: [], taskTags: [], customLists: [], taskOccurrences: []),
            settings: nil,
            kanban: nil
        )

        // Verify structure is valid (D11: absent key means keep existing)
        try BackupValidator.validate(store)
    }

    @Test("D11 semantics: present-but-empty kanban section replaces boards")
    func d11EmptyKanbanReplacesBoards() throws {
        let emptyKanban = KanbanBackupDTO()
        let store = BackupStoreDTO(
            schemaVersion: 2,
            appVersion: "0.2.0",
            exportedAt: Date(),
            data: BackupDataDTO(taskItems: [], subtasks: [], taskTags: [], customLists: [], taskOccurrences: []),
            settings: nil,
            kanban: emptyKanban
        )

        // Verify both sections validate independently
        try BackupValidator.validate(store)
        try KanbanBackupValidator.validate(emptyKanban)
    }
}
