import Foundation
import AppKit
import Observation

/// Working state of the Weekly Summary sheet: the chosen week and tasks, the
/// provider/model/effort, an in-flight generation, and the editable result.
/// Generation runs on an immutable snapshot taken at Generate time; stale
/// results (from a cancelled or superseded run) are discarded by generation id.
@MainActor
@Observable
final class WeeklySummarySession {
    enum Phase: Equatable {
        case selecting
        case generating(startedAt: Date)
        case result
    }

    var weekAnchor: Date
    var selectedIDs: Set<UUID> = []
    private(set) var phase: Phase = .selecting

    private(set) var provider: SummaryProvider
    private(set) var modelLists: [SummaryProvider: SummaryModelList] = [:]
    private(set) var modelID: String
    private(set) var effort: EffortChoice = .cliDefault
    /// Shown when a remembered effort didn't fit the newly chosen model.
    private(set) var effortNote: String?
    private(set) var isRefreshingModels = false
    private(set) var modelRefreshError: String?

    /// The editable summary text (what Copy copies).
    var resultText = ""
    private(set) var lastResult: SummaryResult?
    private(set) var error: WeeklySummaryError?
    private(set) var errorPresentation: SummaryErrorPresenter.Presentation?

    private let generator: SummaryGenerating
    private let catalog: SummaryModelCatalogProviding
    private let preferences: SummaryPreferences
    private var snapshot: [SummaryTaskSnapshot] = []
    private var generationTask: Task<Void, Never>?
    private var generationID = 0

    init(weekAnchor: Date,
         generator: SummaryGenerating,
         catalog: SummaryModelCatalogProviding,
         preferences: SummaryPreferences = SummaryPreferences()) {
        self.weekAnchor = weekAnchor
        self.generator = generator
        self.catalog = catalog
        self.preferences = preferences
        self.provider = preferences.provider
        self.modelID = preferences.modelID(for: preferences.provider)
    }

    // MARK: - Models & effort

    /// The current provider's models plus any custom ids the user has entered,
    /// and the remembered model if it's no longer listed (so it isn't lost).
    var modelOptions: [SummaryModelOption] {
        var options = modelLists[provider]?.models ?? [.cliDefault]
        var known = Set(options.map(\.id))
        let customs = preferences.customModelIDs(for: provider) + [modelID]
        for id in customs where !id.isEmpty && !known.contains(id) {
            options.append(SummaryModelOption(id: id, label: id, source: .custom, supportedEfforts: nil, defaultEffort: nil))
            known.insert(id)
        }
        return options
    }

    var selectedModel: SummaryModelOption {
        modelOptions.first { $0.id == modelID } ?? .cliDefault
    }

    var effortChoices: [EffortChoice] {
        SummaryEffortResolver.choices(provider: provider, model: selectedModel)
    }

    var modelListDescription: String? {
        guard let list = modelLists[provider] else { return nil }
        var text = list.sourceDescription
        if let date = list.refreshedAt { text += " · updated \(date.formatted(.relative(presentation: .named)))" }
        if list.isStale { text += " · refresh failed, showing the last list" }
        return text
    }

    func loadModels(refresh: Bool = false) async {
        let target = provider
        isRefreshingModels = true
        modelRefreshError = nil
        defer { isRefreshingModels = false }
        do {
            let list = try await catalog.models(for: target, refresh: refresh)
            modelLists[target] = list
            if list.isStale { modelRefreshError = "Couldn't refresh the model list; showing the last one." }
        } catch let error as WeeklySummaryError {
            modelRefreshError = SummaryErrorPresenter.present(error).title
        } catch {
            modelRefreshError = error.localizedDescription
        }
        if target == provider { reconcileEffort() }
    }

    func selectProvider(_ newProvider: SummaryProvider) {
        guard newProvider != provider else { return }
        provider = newProvider
        preferences.provider = newProvider
        modelID = preferences.modelID(for: newProvider)
        effortNote = nil
        reconcileEffort()
        if modelLists[newProvider] == nil {
            Task { await loadModels() }
        }
    }

    func selectModel(_ id: String) {
        modelID = id
        preferences.setModelID(id, for: provider)
        reconcileEffort()
    }

    /// Adds and selects a typed model id (passed verbatim to the CLI).
    func useCustomModel(_ rawID: String) {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        preferences.addCustomModelID(id, for: provider)
        selectModel(id)
    }

    func selectEffort(_ choice: EffortChoice) {
        effort = choice
        effortNote = nil
        preferences.setEffort(choice, for: provider, modelID: modelID)
    }

    private func reconcileEffort() {
        let remembered = preferences.effort(for: provider, modelID: modelID)
        let reconciled = SummaryEffortResolver.reconcile(remembered: remembered, provider: provider, model: selectedModel)
        effort = reconciled.choice
        effortNote = reconciled.note
        if remembered != reconciled.choice { preferences.setEffort(reconciled.choice, for: provider, modelID: modelID) }
    }

    // MARK: - Week & selection

    func shiftWeek(by weeks: Int, calendar: Calendar = .current) {
        guard let shifted = calendar.date(byAdding: .weekOfYear, value: weeks, to: weekAnchor) else { return }
        weekAnchor = shifted
        selectedIDs.removeAll()   // a selection only makes sense within one week
    }

    func toggle(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    /// Selects every existing row of `seriesID` within `weekTasks` (never
    /// another week, never synthesized occurrences).
    func selectSeries(_ seriesID: UUID, in weekTasks: [SummaryTaskSnapshot]) {
        for task in weekTasks where task.seriesID == seriesID { selectedIDs.insert(task.id) }
    }

    func setDay(_ dayTasks: [SummaryTaskSnapshot], selected: Bool) {
        for task in dayTasks {
            if selected { selectedIDs.insert(task.id) } else { selectedIDs.remove(task.id) }
        }
    }

    func selectAllWithNotes(in weekTasks: [SummaryTaskSnapshot]) {
        for task in weekTasks where task.hasNotes { selectedIDs.insert(task.id) }
    }

    func clearSelection() { selectedIDs.removeAll() }

    /// Generate needs at least one selected task that actually has notes.
    func canGenerate(weekTasks: [SummaryTaskSnapshot]) -> Bool {
        weekTasks.contains { selectedIDs.contains($0.id) && $0.hasNotes }
    }

    // MARK: - Generation

    var isGenerating: Bool {
        if case .generating = phase { return true }
        return false
    }

    /// Captures the selected rows and starts a new generation.
    func generate(weekTasks: [SummaryTaskSnapshot]) {
        snapshot = weekTasks.filter { selectedIDs.contains($0.id) }
        start()
    }

    /// Re-runs the captured snapshot with the current provider/model/effort.
    func regenerate() {
        guard !snapshot.isEmpty else { return }
        start()
    }

    func cancel() {
        generationTask?.cancel()
    }

    /// Back to the selection; the next Generate takes a fresh snapshot.
    func changeSelection() {
        cancel()
        phase = .selecting
        dismissError()
    }

    func dismissError() {
        error = nil
        errorPresentation = nil
    }

    private func start() {
        generationTask?.cancel()
        generationID += 1
        let id = generationID
        let hadResult = lastResult != nil
        dismissError()

        let payload: Data
        do {
            payload = try SummaryInputBuilder.payload(for: snapshot)
        } catch let failure as WeeklySummaryError {
            present(failure, provider: provider)
            return
        } catch {
            present(.invalidResponse(provider, SummaryErrorDetail(message: error.localizedDescription)), provider: provider)
            return
        }

        let request = SummaryRequest(
            instructions: SummaryPrompt.instructions,
            payload: payload,
            config: SummaryRunConfig(provider: provider, modelID: modelID.isEmpty ? nil : modelID, effort: effort.cliValue)
        )
        phase = .generating(startedAt: Date())
        let generator = generator
        generationTask = Task { [weak self] in
            do {
                let result = try await generator.generate(request)
                guard let self, id == self.generationID else { return }
                self.lastResult = result
                self.resultText = result.text
                self.phase = .result
            } catch {
                guard let self, id == self.generationID else { return }
                let failure = (error as? WeeklySummaryError) ?? (error is CancellationError ? .cancelled
                    : .cliFailed(request.config.provider, SummaryErrorDetail(message: error.localizedDescription)))
                // A failed regenerate keeps the previous (possibly edited) draft.
                self.phase = hadResult ? .result : .selecting
                await self.presentWithAuthContext(failure, provider: request.config.provider)
            }
        }
    }

    private func present(_ failure: WeeklySummaryError, provider: SummaryProvider, authSetup: SummaryAuthSetup = .unknown) {
        error = failure
        errorPresentation = SummaryErrorPresenter.present(failure, authSetup: authSetup)
    }

    private func presentWithAuthContext(_ failure: WeeklySummaryError, provider: SummaryProvider) async {
        present(failure, provider: provider)   // show at once; refine auth advice below
        guard failure.isAuthRelated else { return }
        let setup = await generator.authSetup(for: provider)
        if error == failure { present(failure, provider: provider, authSetup: setup) }
    }

    // MARK: - Copy

    /// Copies the current (possibly edited) summary to the clipboard.
    @discardableResult
    func copyToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        let text = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
