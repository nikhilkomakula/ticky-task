import Testing
import Foundation
import AppKit
@testable import TickyTask

@Suite("SummaryEffortResolver")
struct SummaryEffortResolverTests {
    @Test("Codex with known model and supported efforts")
    func codexKnownModel() {
        let model = SummaryModelOption(
            id: "gpt-5.5",
            label: "GPT-5.5",
            source: .catalog,
            supportedEfforts: ["low", "medium", "high", "xhigh"],
            defaultEffort: "medium"
        )
        let choices = SummaryEffortResolver.choices(model: model)

        // Should have modelDefault + the supported levels.
        #expect(choices.contains(.modelDefault("medium")))
        #expect(choices.contains(.level("low")))
        #expect(choices.contains(.level("medium")))
        #expect(choices.contains(.level("high")))
        #expect(choices.contains(.level("xhigh")))
        #expect(!choices.contains(.cliDefault))
    }

    @Test("Codex CLI default model offers CLI default + standard levels")
    func codexCLIDefaultModel() {
        let model = SummaryModelOption.cliDefault
        let choices = SummaryEffortResolver.choices(model: model)

        #expect(choices.contains(.cliDefault))
        #expect(choices.contains(.level("low")))
        #expect(choices.contains(.level("max")))
    }

    @Test("Codex custom model with unknown efforts")
    func codexCustomModelUnknownEfforts() {
        let model = SummaryModelOption(
            id: "my-custom-model",
            label: "Custom Model",
            source: .custom,
            supportedEfforts: nil,
            defaultEffort: nil
        )
        let choices = SummaryEffortResolver.choices(model: model)

        #expect(choices.contains(.cliDefault))
        #expect(choices.contains(.level("low")))
        #expect(choices.contains(.level("max")))
    }

    @Test("reconcile keeps remembered if still offered")
    func reconcileKeepsRemembered() {
        let model = SummaryModelOption(
            id: "model",
            label: "Model",
            source: .catalog,
            supportedEfforts: ["low", "high"],
            defaultEffort: "low"
        )

        let result = SummaryEffortResolver.reconcile(
            remembered: .level("high"),
            model: model
        )
        #expect(result.choice == .level("high"))
        #expect(result.note == nil)
    }

    @Test("reconcile uses first offered when no remembered")
    func reconcileNoneOffersFirst() {
        let model = SummaryModelOption(
            id: "model",
            label: "Model",
            source: .catalog,
            supportedEfforts: ["high", "max"],
            defaultEffort: "high"
        )

        let result = SummaryEffortResolver.reconcile(
            remembered: nil,
            model: model
        )
        // First offered is modelDefault.
        #expect(result.choice == .modelDefault("high"))
        #expect(result.note == nil)
    }

    @Test("reconcile switches and notes when remembered not offered")
    func reconcilesNotOfferedWithNote() {
        let model = SummaryModelOption(
            id: "gpt-5.5",
            label: "GPT-5.5",
            source: .catalog,
            supportedEfforts: ["low", "medium", "high"],
            defaultEffort: "medium"
        )

        let result = SummaryEffortResolver.reconcile(
            remembered: .level("xhigh"),
            model: model
        )
        #expect(result.choice != .level("xhigh"))
        #expect(result.note != nil)
    }

    @Test("reconcile GLM case: remembered modelDefault differs from new default")
    func reconcileGLMDifferentDefault() {
        // GLM supports high/max, default max; remembered was modelDefault(xhigh).
        let model = SummaryModelOption(
            id: "glm-5.2",
            label: "GLM 5.2",
            source: .catalog,
            supportedEfforts: ["high", "max"],
            defaultEffort: "max"
        )

        let result = SummaryEffortResolver.reconcile(
            remembered: .modelDefault("xhigh"),
            model: model
        )
        #expect(result.choice == .modelDefault("max"))
        #expect(result.note != nil)
        let noteContains = result.note?.lowercased() ?? ""
        #expect(noteContains.contains("extra high") || noteContains.contains("model default"))
    }

    @Test("label for cliDefault")
    func labelCLIDefault() {
        let label = SummaryEffortResolver.label(for: .cliDefault)
        #expect(label == "CLI default")
    }

    @Test("label for standard levels")
    func labelStandardLevels() {
        #expect(SummaryEffortResolver.label(for: .level("low")) == "Low")
        #expect(SummaryEffortResolver.label(for: .level("medium")) == "Medium")
        #expect(SummaryEffortResolver.label(for: .level("high")) == "High")
        #expect(SummaryEffortResolver.label(for: .level("xhigh")) == "Extra high")
        #expect(SummaryEffortResolver.label(for: .level("max")) == "Max")
        #expect(SummaryEffortResolver.label(for: .level("ultra")) == "Ultra")
    }

    @Test("label for modelDefault")
    func labelModelDefault() {
        let label = SummaryEffortResolver.label(for: .modelDefault("medium"))
        #expect(label == "Model default (Medium)")
    }

    @Test("label for unknown level")
    func labelUnknown() {
        let label = SummaryEffortResolver.label(for: .level("unknownlevel"))
        #expect(label == "Unknownlevel")
    }
}

@Suite("Weekly Summary — session lifecycle")
@MainActor
struct WeeklySummarySessionReviewTests {
    private func fixture() -> (WeeklySummarySession, SummarySessionReviewGenerator, SummaryPreferences, UserDefaults, String) {
        let suite = "WeeklySummarySessionReview-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = SummaryPreferences(defaults: defaults)
        let generator = SummarySessionReviewGenerator()
        let session = WeeklySummarySession(weekAnchor: Date(timeIntervalSince1970: 1_792_022_400),
                                          generator: generator, catalog: StubSummaryModelCatalog(), preferences: preferences)
        return (session, generator, preferences, defaults, suite)
    }

    private func task(title: String = "Selected", notes: SummaryNotes = .legacyMarkdown("Verified recovery."),
                      series: UUID? = nil, day: String = "2026-10-14") -> SummaryTaskSnapshot {
        SummaryTaskSnapshot(id: UUID(), seriesID: series, dayKey: day, sortIndex: 0,
                            title: title, isDone: false, subtasks: [], notes: notes)
    }

    private func settle(_ session: WeeklySummarySession) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while session.isGenerating && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!session.isGenerating, "The controlled generation should have settled")
        // Let the MainActor continuation run even when Change selection already
        // changed the phase before a cancelled generator returned.
        for _ in 0..<25 { await Task.yield() }
    }

    @Test("Day, notes-only and series selection use row identity; changing weeks clears selection")
    func selectionAndWeekNavigation() {
        let (session, _, _, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let series = UUID()
        let first = task(title: "Same title", series: series)
        let repeated = task(title: "Same title", series: series, day: "2026-10-15")
        let unrelated = task(title: "Same title", notes: .none)
        let tasks = [first, repeated, unrelated]
        #expect(session.selectedIDs.isEmpty)
        session.toggle(unrelated.id)
        #expect(!session.canGenerate(weekTasks: tasks))
        session.selectSeries(series, in: tasks)
        #expect(session.selectedIDs == Set(tasks.map(\.id)))
        session.clearSelection()
        session.setDay([first, unrelated], selected: true)
        session.setDay([first, unrelated], selected: false)
        #expect(session.selectedIDs.isEmpty)
        session.selectAllWithNotes(in: tasks)
        #expect(session.selectedIDs == [first.id, repeated.id])
        #expect(session.canGenerate(weekTasks: tasks))
        let previousAnchor = session.weekAnchor
        session.shiftWeek(by: 1)
        #expect(session.weekAnchor > previousAnchor)
        #expect(session.selectedIDs.isEmpty)
    }

    @Test("Regenerate reuses captured tasks and applies current model, effort and instructions")
    func regenerateSnapshotAndCurrentConfiguration() async throws {
        let (session, generator, _, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = task()
        let unselected = task(title: "Unselected")
        session.selectedIDs = [selected.id]
        session.generate(weekTasks: [selected, unselected])
        let first = await generator.request(at: 0)
        #expect(String(decoding: first.payload, as: UTF8.self).contains("Selected"))
        #expect(!String(decoding: first.payload, as: UTF8.self).contains("Unselected"))
        await generator.succeed(0, text: "Initial draft")
        try await settle(session)
        session.selectedIDs = [unselected.id]
        session.selectModel("different-model")
        session.selectEffort(.level("high"))
        session.customInstructions = "Write for my manager."
        session.regenerate()
        let second = await generator.request(at: 1)
        #expect(second.payload == first.payload)
        #expect(second.config.modelID == "different-model")
        #expect(second.config.effort == "high")
        #expect(second.instructions.contains("Write for my manager."))
        await generator.succeed(1, text: "New draft")
        try await settle(session)
        #expect(session.resultText == "New draft")
    }

    @Test("Failed regenerate preserves edited text and selection")
    func failedRegeneratePreservesEditedDraft() async throws {
        let (session, generator, _, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = task()
        session.selectedIDs = [selected.id]
        session.generate(weekTasks: [selected])
        _ = await generator.request(at: 0)
        await generator.succeed(0, text: "Original draft")
        try await settle(session)
        session.resultText = "My edited draft"
        session.regenerate()
        _ = await generator.request(at: 1)
        await generator.fail(1, with: .networkFailure(.codex, SummaryErrorDetail(message: "Offline")))
        try await settle(session)
        #expect(session.phase == .result)
        #expect(session.resultText == "My edited draft")
        #expect(session.lastResult?.text == "Original draft")
        #expect(session.errorPresentation != nil)
        #expect(session.selectedIDs == [selected.id])
    }

    @Test("Starting a new generation discards a superseded success")
    func supersededResultIsDiscarded() async throws {
        let (session, generator, _, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = task()
        session.selectedIDs = [selected.id]
        session.generate(weekTasks: [selected])
        _ = await generator.request(at: 0)
        session.generate(weekTasks: [selected])
        _ = await generator.request(at: 1)
        await generator.succeed(1, text: "Current draft")
        try await settle(session)
        await generator.succeed(0, text: "Stale draft")
        try await settle(session)
        #expect(session.resultText == "Current draft")
        #expect(session.phase == .result)
    }

    @Test("Cancel discards a success returned after cancellation")
    func cancelRejectsLateSuccess() async throws {
        let (session, generator, _, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = task()
        session.selectedIDs = [selected.id]
        session.generate(weekTasks: [selected])
        _ = await generator.request(at: 0)
        session.cancel()
        await generator.succeed(0, text: "Cancelled run's late draft")
        try await settle(session)
        #expect(session.phase == .selecting)
        #expect(session.lastResult == nil)
        #expect(session.resultText.isEmpty)
        #expect(session.selectedIDs == [selected.id])
    }

    @Test("Change selection discards a cancelled run's late error")
    func changeSelectionRejectsLateError() async throws {
        let (session, generator, _, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = task()
        session.selectedIDs = [selected.id]
        session.generate(weekTasks: [selected])
        _ = await generator.request(at: 0)
        session.changeSelection()
        await generator.fail(0, with: .networkFailure(.codex, SummaryErrorDetail(message: "Old run failed")))
        try await settle(session)
        #expect(session.phase == .selecting)
        #expect(session.error == nil)
        #expect(session.errorPresentation == nil)
    }

    @Test("Generation uses a remembered effort before the first catalog load finishes")
    func rememberedEffortBeforeCatalogLoad() async throws {
        let suite = "WeeklySummarySessionReview-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SummaryPreferences(defaults: defaults)
        preferences.setModelID("remembered-model", for: .chatGPTAccount)
        preferences.setEffort(.level("high"), for: .chatGPTAccount, modelID: "remembered-model")
        let generator = SummarySessionReviewGenerator()
        let session = WeeklySummarySession(weekAnchor: Date(), generator: generator,
                                          catalog: StubSummaryModelCatalog(), preferences: preferences)
        let selected = task()
        session.selectedIDs = [selected.id]
        session.generate(weekTasks: [selected])
        let request = await generator.request(at: 0)
        #expect(request.config.modelID == "remembered-model")
        #expect(request.config.effort == "high")
        await generator.succeed(0, text: "Draft")
        try await settle(session)
    }

    @Test("Copy uses edited text and does not touch the general pasteboard")
    func copyCurrentEditedText() {
        let (session, _, _, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        session.resultText = "My edited update\n- Verified recovery"
        #expect(session.copyToPasteboard(pasteboard))
        #expect(pasteboard.string(forType: .string) == session.resultText)
        session.resultText = " \n "
        #expect(!session.copyToPasteboard(pasteboard))
    }
}

/// Deliberately ignores task cancellation, modelling completion racing with
/// Cancel after the underlying process has already produced a response.
private actor SummarySessionReviewGenerator: SummaryGenerating {
    private var requests: [SummaryRequest] = []
    private var pending: [Int: CheckedContinuation<SummaryResult, Error>] = [:]
    private var observers: [Int: CheckedContinuation<SummaryRequest, Never>] = [:]

    func generate(_ request: SummaryRequest) async throws -> SummaryResult {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            observers.removeValue(forKey: index)?.resume(returning: request)
        }
    }

    func request(at index: Int) async -> SummaryRequest {
        if requests.indices.contains(index) { return requests[index] }
        return await withCheckedContinuation { observers[index] = $0 }
    }

    func succeed(_ index: Int, text: String) {
        let result = SummaryResult(text: text, config: requests[index].config, resolvedModel: nil,
                                   duration: .milliseconds(1), usage: nil)
        pending.removeValue(forKey: index)?.resume(returning: result)
    }

    func fail(_ index: Int, with error: WeeklySummaryError) {
        pending.removeValue(forKey: index)?.resume(throwing: error)
    }
}
