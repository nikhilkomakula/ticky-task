import Foundation
import AppKit
import Observation

/// Scope of the Kanban summary: by individual resource or the whole board.
enum KanbanSummaryScope: Equatable, Sendable {
    case byResource
    case wholeProject
}

/// Working state of the Kanban Summary sheet: scope, selected cards,
/// Codex connection/model/effort, an in-flight generation, and the editable result.
@MainActor
@Observable
final class KanbanSummarySession {
    enum Phase: Equatable {
        case selecting
        case generating(startedAt: Date)
        case result
    }

    var scope: KanbanSummaryScope = .byResource
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

    /// The user's own instructions, applied on top of the built-in Kanban rules.
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
    private let preferences: KanbanSummaryPreferences
    private var snapshot: [KanbanTaskSnapshot] = []
    private var generationTask: Task<Void, Never>?
    private var generationID = 0
    private var modelLoadID = 0

    init(generator: SummaryGenerating,
         catalog: SummaryModelCatalogProviding,
         preferences: KanbanSummaryPreferences = KanbanSummaryPreferences()) {
        self.generator = generator
        self.catalog = catalog
        self.preferences = preferences
        let connection = preferences.connection
        let modelID = preferences.modelID(for: connection)
        self.connection = connection
        self.modelID = modelID
        self.effort = preferences.effort(for: connection, modelID: modelID) ?? .cliDefault
        self.customInstructions = preferences.customInstructions
    }

    // MARK: - Connection

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

    func syncConnection() async {
        if syncPreferences() { await loadModels() }
    }

    func refreshAccountStatus() async {
        guard connection == .chatGPTAccount else { return }
        accountStatus = await generator.accountStatus()
    }

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

    func fetchAccountStatus() async -> SummaryAccountStatus { await generator.accountStatus() }
    func performSignIn() async throws { try await generator.signIn() }

    // MARK: - Models & effort

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

    // MARK: - Selection

    func toggle(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    func selectResource(_ resource: String, in cards: [KanbanTaskSnapshot]) {
        for card in cards where card.resource == resource { selectedIDs.insert(card.id) }
    }

    func deselectResource(_ resource: String, in cards: [KanbanTaskSnapshot]) {
        for card in cards where card.resource == resource { selectedIDs.remove(card.id) }
    }

    func selectColumn(_ column: String, in cards: [KanbanTaskSnapshot]) {
        for card in cards where card.column == column { selectedIDs.insert(card.id) }
    }

    func deselectColumn(_ column: String, in cards: [KanbanTaskSnapshot]) {
        for card in cards where card.column == column { selectedIDs.remove(card.id) }
    }

    func selectAllWithNotes(in cards: [KanbanTaskSnapshot]) {
        for card in cards where card.hasNotes { selectedIDs.insert(card.id) }
    }

    func clearSelection() { selectedIDs.removeAll() }

    /// Generate needs at least one selected card that actually has notes.
    func canGenerate(cards: [KanbanTaskSnapshot]) -> Bool {
        cards.contains { selectedIDs.contains($0.id) && $0.hasNotes }
    }

    // MARK: - Generation

    var isGenerating: Bool {
        if case .generating = phase { return true }
        return false
    }

    /// Captures the selected cards and starts a new generation.
    func generate(cards: [KanbanTaskSnapshot]) {
        snapshot = cards.filter { selectedIDs.contains($0.id) }
        start()
    }

    /// Re-runs the captured snapshot with the current connection/model/effort/instructions.
    func regenerate() {
        guard !snapshot.isEmpty else { return }
        start()
    }

    /// Stops a running generation; anything it still reports is ignored.
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

        if syncPreferences() { Task { await loadModels() } }

        let payload: Data
        do {
            payload = try KanbanSummaryInputBuilder.payload(for: snapshot)
        } catch let failure as WeeklySummaryError {
            present(failure)
            return
        } catch {
            present(.invalidResponse(.codex, SummaryErrorDetail(message: error.localizedDescription)))
            return
        }

        let request = SummaryRequest(
            instructions: KanbanSummaryPrompt.compose(customInstructions: customInstructions),
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
        present(failure)
        guard failure.isAuthRelated, id == generationID else { return }
        let setup = await generator.authSetup(for: connection)
        if id == generationID && error == failure { present(failure, authSetup: setup) }
    }

    // MARK: - Copy

    @discardableResult
    func copyToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(resultText, forType: .string)
    }
}
