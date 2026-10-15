import Foundation
import AppKit
import Observation

/// Working state of the Weekly Summary sheet: the chosen week and tasks, the
/// Codex connection/model/effort, an in-flight generation, and the editable
/// result. Generation runs on an immutable snapshot taken at Generate time;
/// stale results (from a cancelled or superseded run) are discarded by id.
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

    private(set) var connection: SummaryConnectionTarget
    private(set) var modelLists: [String: SummaryModelList] = [:]
    private(set) var modelID: String
    private(set) var effort: EffortChoice = .cliDefault
    /// Shown when a remembered effort didn't fit the newly chosen model.
    private(set) var effortNote: String?
    private(set) var isRefreshingModels = false
    private(set) var modelRefreshError: String?

    private(set) var accountStatus: SummaryAccountStatus = .unknown
    private(set) var isSigningIn = false

    /// The user's own instructions, applied on top of the built-in rules.
    var customInstructions: String {
        didSet { preferences.customInstructions = customInstructions }
    }

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
    private var modelLoadID = 0

    init(weekAnchor: Date,
         generator: SummaryGenerating,
         catalog: SummaryModelCatalogProviding,
         preferences: SummaryPreferences = SummaryPreferences()) {
        self.weekAnchor = weekAnchor
        self.generator = generator
        self.catalog = catalog
        self.preferences = preferences
        let connection = preferences.connection
        let modelID = preferences.modelID(for: connection)
        self.connection = connection
        self.modelID = modelID
        // The remembered effort applies at once; the model list may refine it later.
        self.effort = preferences.effort(for: connection, modelID: modelID) ?? .cliDefault
        self.customInstructions = preferences.customInstructions
    }

    // MARK: - Connection

    /// Picks up changes made elsewhere (Settings › AI) to the connection and
    /// instructions. Returns whether the connection changed.
    @discardableResult
    func syncPreferences() -> Bool {
        if customInstructions != preferences.customInstructions { customInstructions = preferences.customInstructions }
        let current = preferences.connection
        guard current != connection else { return false }
        connection = current
        modelID = preferences.modelID(for: current)
        effortNote = nil
        reconcileEffort()
        return true
    }

    /// `syncPreferences`, then loads the new connection's models if it changed.
    func syncConnection() async {
        if syncPreferences() { await loadModels() }
    }

    func refreshAccountStatus() async {
        guard connection == .chatGPTAccount else { return }
        accountStatus = await generator.accountStatus()
    }

    /// Runs `codex login` (the browser opens for the ChatGPT sign-in).
    func signIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await generator.signIn()
            dismissError()
        } catch let failure as WeeklySummaryError {
            present(failure, authSetup: .accountLogin)
        } catch {
            present(.notSignedIn(.codex, SummaryErrorDetail(message: error.localizedDescription)), authSetup: .accountLogin)
        }
        accountStatus = await generator.accountStatus()
        await loadModels(refresh: true)
    }

    /// Pass-throughs so the shared connection form can use this session's generator.
    func fetchAccountStatus() async -> SummaryAccountStatus { await generator.accountStatus() }
    func performSignIn() async throws { try await generator.signIn() }

    // MARK: - Models & effort

    /// The connection's models plus custom ids the user has entered, and the
    /// remembered model if it's no longer listed (so it isn't lost).
    var modelOptions: [SummaryModelOption] {
        var options = modelLists[connection.catalogKey]?.models ?? [.cliDefault]
        var known = Set(options.map(\.id))
        for id in preferences.customModelIDs(for: connection) + [modelID] where !id.isEmpty && !known.contains(id) {
            options.append(SummaryModelOption(id: id, label: id, source: .custom, supportedEfforts: nil, defaultEffort: nil))
            known.insert(id)
        }
        return options
    }

    var selectedModel: SummaryModelOption {
        modelOptions.first { $0.id == modelID } ?? .cliDefault
    }

    var effortChoices: [EffortChoice] {
        SummaryEffortResolver.choices(model: selectedModel)
    }

    var modelListDescription: String? {
        guard let list = modelLists[connection.catalogKey] else { return nil }
        var text = list.sourceDescription
        if let date = list.refreshedAt { text += " · updated \(date.formatted(.relative(presentation: .named)))" }
        if list.isStale { text += " · refresh failed, showing the last list" }
        return text
    }

    /// Only the newest load updates the spinner, error, and effort, so an older
    /// reply (possibly for another connection) can't overwrite them.
    func loadModels(refresh: Bool = false) async {
        let target = connection
        modelLoadID += 1
        let id = modelLoadID
        isRefreshingModels = true
        modelRefreshError = nil
        var refreshError: String?
        do {
            let list = try await catalog.models(for: target, refresh: refresh)
            guard id == modelLoadID else { return }
            modelLists[target.catalogKey] = list
            if list.isStale { refreshError = "Couldn't refresh the model list; showing the last one." }
        } catch let failure as WeeklySummaryError {
            let presentation = SummaryErrorPresenter.present(failure, connection: target)
            refreshError = "\(presentation.title). \(presentation.message)"
        } catch {
            refreshError = error.localizedDescription
        }
        guard id == modelLoadID else { return }
        isRefreshingModels = false
        modelRefreshError = refreshError
        if target == connection { reconcileEffort() }
    }

    func selectModel(_ id: String) {
        modelID = id
        preferences.setModelID(id, for: connection)
        reconcileEffort()
    }

    /// Adds and selects a typed model id (passed verbatim to Codex).
    func useCustomModel(_ rawID: String) {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        preferences.addCustomModelID(id, for: connection)
        selectModel(id)
    }

    func selectEffort(_ choice: EffortChoice) {
        effort = choice
        effortNote = nil
        preferences.setEffort(choice, for: connection, modelID: modelID)
    }

    private func reconcileEffort() {
        let remembered = preferences.effort(for: connection, modelID: modelID)
        // Without this connection's model list there's nothing to check against:
        // keep the remembered choice rather than overwrite it.
        guard modelLists[connection.catalogKey] != nil else {
            effort = remembered ?? .cliDefault
            effortNote = nil
            return
        }
        let reconciled = SummaryEffortResolver.reconcile(remembered: remembered, model: selectedModel)
        effort = reconciled.choice
        effortNote = reconciled.note
        if remembered != reconciled.choice { preferences.setEffort(reconciled.choice, for: connection, modelID: modelID) }
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

    /// Re-runs the captured snapshot with the current connection/model/effort/instructions.
    func regenerate() {
        guard !snapshot.isEmpty else { return }
        start()
    }

    /// Stops a running generation; anything it still reports is ignored. The
    /// selection and any earlier (possibly edited) draft are kept.
    func cancel() {
        guard isGenerating else { return }
        invalidateGeneration()
        phase = lastResult != nil ? .result : .selecting
        present(.cancelled)
    }

    /// Back to the selection; the next Generate takes a fresh snapshot.
    func changeSelection() {
        invalidateGeneration()
        phase = .selecting
        dismissError()
    }

    private func invalidateGeneration() {
        generationTask?.cancel()
        generationTask = nil
        generationID += 1
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

        // Settings › AI may have changed while the sheet was open.
        if syncPreferences() { Task { await loadModels() } }

        let payload: Data
        do {
            payload = try SummaryInputBuilder.payload(for: snapshot)
        } catch let failure as WeeklySummaryError {
            present(failure)
            return
        } catch {
            present(.invalidResponse(.codex, SummaryErrorDetail(message: error.localizedDescription)))
            return
        }

        let request = SummaryRequest(
            instructions: SummaryPrompt.compose(customInstructions: customInstructions),
            payload: payload,
            config: SummaryRunConfig(connection: connection, modelID: modelID.isEmpty ? nil : modelID,
                                     effort: effort.cliValue)
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
                    : .cliFailed(.codex, SummaryErrorDetail(message: error.localizedDescription)))
                // A failed regenerate keeps the previous (possibly edited) draft.
                self.phase = hadResult ? .result : .selecting
                await self.presentWithAuthContext(failure, connection: request.config.connection, generationID: id)
            }
        }
    }

    private func present(_ failure: WeeklySummaryError, authSetup: SummaryAuthSetup = .unknown) {
        error = failure
        errorPresentation = SummaryErrorPresenter.present(failure, authSetup: authSetup, connection: connection)
    }

    private func presentWithAuthContext(_ failure: WeeklySummaryError, connection: SummaryConnectionTarget, generationID id: Int) async {
        present(failure)   // show at once; refine auth advice below
        guard failure.isAuthRelated, id == generationID else { return }
        let setup = await generator.authSetup(for: connection)
        if id == generationID && error == failure { present(failure, authSetup: setup) }
    }

    // MARK: - Copy

    /// Copies the current (possibly edited) summary to the clipboard.
    @discardableResult
    func copyToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(resultText, forType: .string)
    }
}
