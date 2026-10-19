import SwiftUI
import SwiftData

/// The Kanban Summary sheet: pick cards by resource or whole board, choose
/// Claude/Codex + model + effort, generate one update, then edit and copy it.
struct KanbanSummarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: KanbanSummarySession
    let project: KanbanProject

    private var allCards: [KanbanTaskSnapshot] { KanbanTaskSnapshot.cards(of: project) }

    private var resourceGroups: [String: [KanbanTaskSnapshot]] {
        Dictionary(grouping: allCards) { $0.resource }
    }

    private var sortedResources: [String] {
        resourceGroups.keys.sorted { lhs, rhs in
            if lhs == "Unassigned" { return false }
            if rhs == "Unassigned" { return true }
            return lhs < rhs
        }
    }

    var body: some View {
        let cards = allCards
        VStack(spacing: 0) {
            header
            Divider()
            if let presentation = session.errorPresentation {
                KanbanSummaryErrorBanner(presentation: presentation, onDismiss: session.dismissError)
                    .padding([.horizontal, .top], 12)
            }
            switch session.phase {
            case .result:
                KanbanSummaryResultView(session: session)
            case .selecting, .generating:
                KanbanSummarySelectionView(session: session, project: project, allCards: cards)
                    .disabled(session.isGenerating)
                    .overlay {
                        if case .generating(let startedAt) = session.phase {
                            KanbanSummaryGeneratingOverlay(session: session, startedAt: startedAt)
                        }
                    }
            }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 620, idealHeight: 700)
        .task { await session.loadModels() }
        .onDisappear { session.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await session.syncConnection() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
            Text("Kanban Summary").font(.headline)
            Spacer()
            if session.phase != .result {
                Text(project.name)
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("kanban-summary-project")
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(session.isGenerating)
                .accessibilityIdentifier("kanban-summary-done")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }
}

// MARK: - Selection

private struct KanbanSummarySelectionView: View {
    @Bindable var session: KanbanSummarySession
    let project: KanbanProject
    let allCards: [KanbanTaskSnapshot]

    private var selectedCount: Int { allCards.filter { session.selectedIDs.contains($0.id) }.count }
    private var selectedWithNotes: Int { allCards.filter { session.selectedIDs.contains($0.id) && $0.hasNotes }.count }

    private var resourceGroups: [String: [KanbanTaskSnapshot]] {
        Dictionary(grouping: allCards) { $0.resource }
    }

    private var sortedResources: [String] {
        resourceGroups.keys.sorted { lhs, rhs in
            if lhs == "Unassigned" { return false }
            if rhs == "Unassigned" { return true }
            return lhs < rhs
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose cards to include in one overall update.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Scope", selection: $session.scope) {
                    Text("By resource").tag(KanbanSummaryScope.byResource)
                    Text("Whole board").tag(KanbanSummaryScope.wholeProject)
                }
                .frame(maxWidth: 160)
                Button("Select all with notes") { session.selectAllWithNotes(in: allCards) }
                    .disabled(!allCards.contains(where: \.hasNotes))
                    .accessibilityIdentifier("kanban-summary-select-notes")
                Button("Clear") { session.clearSelection() }
                    .disabled(session.selectedIDs.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if allCards.isEmpty {
                ContentUnavailableView("No cards on this board", systemImage: "square.grid.2x2",
                                       description: Text("Create some cards to get started."))
                    .frame(maxHeight: .infinity)
            } else if session.scope == .byResource {
                scrollViewByResource
            } else {
                scrollViewWholeBoard
            }

            Divider()
            KanbanSummaryConfigurationBar(session: session)
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedCount) selected · \(selectedWithNotes) with notes")
                        .font(.callout.weight(.medium))
                        .accessibilityIdentifier("kanban-summary-selection-count")
                    Text(disclosure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    session.generate(cards: allCards)
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canGenerate(cards: allCards))
                .help(session.canGenerate(cards: allCards) ? "Generate the summary" : "Select at least one card that has notes")
                .accessibilityIdentifier("kanban-summary-generate")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var scrollViewByResource: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(sortedResources, id: \.self) { resource in
                    let cards = (resourceGroups[resource] ?? []).sorted { $0.title < $1.title }
                    KanbanResourceSection(session: session, resource: resource, cards: cards)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var scrollViewWholeBoard: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                let columnGroups = Dictionary(grouping: allCards) { $0.column }
                let sortedColumns = columnGroups.keys.sorted()
                ForEach(sortedColumns, id: \.self) { column in
                    let cards = (columnGroups[column] ?? []).sorted { $0.title < $1.title }
                    KanbanColumnSection(session: session, column: column, cards: cards)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var disclosure: String {
        let destination = session.connection.isLocal
            ? "to your local model server"
            : (session.connection == .chatGPTAccount ? "to OpenAI using your ChatGPT account" : "to the provider in your Codex configuration")
        return "Sends the selected cards through the Codex CLI \(destination). Summarizes current notes and statuses."
    }
}

private struct KanbanResourceSection: View {
    @Bindable var session: KanbanSummarySession
    let resource: String
    let cards: [KanbanTaskSnapshot]

    private var selectedHere: Int { cards.filter { session.selectedIDs.contains($0.id) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if !cards.isEmpty {
                    Button {
                        if selectedHere < cards.count {
                            session.selectResource(resource, in: cards)
                        } else {
                            session.deselectResource(resource, in: cards)
                        }
                    } label: {
                        Image(systemName: selectedHere == 0 ? "square" : (selectedHere == cards.count ? "checkmark.square.fill" : "minus.square.fill"))
                            .foregroundStyle(selectedHere == 0 ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(selectedHere < cards.count ? "Select all cards from this resource" : "Deselect this resource")
                }
                Text(resource).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(cards.count)").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(cards, id: \.id) { card in
                    CardRow(session: session, card: card)
                }
            }
            .padding(.leading, 24)
        }
    }
}

private struct KanbanColumnSection: View {
    @Bindable var session: KanbanSummarySession
    let column: String
    let cards: [KanbanTaskSnapshot]

    private var selectedHere: Int { cards.filter { session.selectedIDs.contains($0.id) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if !cards.isEmpty {
                    Button {
                        if selectedHere < cards.count {
                            session.selectColumn(column, in: cards)
                        } else {
                            session.deselectColumn(column, in: cards)
                        }
                    } label: {
                        Image(systemName: selectedHere == 0 ? "square" : (selectedHere == cards.count ? "checkmark.square.fill" : "minus.square.fill"))
                            .foregroundStyle(selectedHere == 0 ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(selectedHere < cards.count ? "Select all cards in this column" : "Deselect this column")
                }
                Text(column).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(cards.count)").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(cards, id: \.id) { card in
                    CardRow(session: session, card: card)
                }
            }
            .padding(.leading, 24)
        }
    }
}

private struct CardRow: View {
    @Bindable var session: KanbanSummarySession
    let card: KanbanTaskSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Button {
                session.toggle(card.id)
            } label: {
                Image(systemName: session.selectedIDs.contains(card.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(session.selectedIDs.contains(card.id) ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("kanban-summary-task-\(card.title)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if card.isCritical {
                        Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
                    }
                    Text(card.title).font(.callout).lineLimit(1)
                    if card.hasNotes {
                        Image(systemName: "note.text").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let preview = card.notes.plainText.split(separator: "\n").first.map(String.init), !preview.isEmpty {
                    Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Configuration Bar

struct KanbanSummaryConfigurationBar: View {
    @Bindable var session: KanbanSummarySession
    var showsInstructions = true
    var identifierPrefix = "kanban-summary"
    @State private var isEnteringCustomModel = false
    @State private var customModel = ""
    @State private var showConnection = false
    @State private var showInstructions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    showConnection = true
                } label: {
                    Label("Codex · \(session.connection.label)", systemImage: session.connection.isLocal ? "desktopcomputer" : "person.crop.circle")
                }
                .help("Change how Codex connects")
                .accessibilityIdentifier("\(identifierPrefix)-connection")
                .popover(isPresented: $showConnection, arrowEdge: .bottom) {
                    SummaryConnectionForm(
                        onChange: { Task { await session.syncConnection(); await session.refreshAccountStatus() } },
                        accountStatus: { await session.fetchAccountStatus() },
                        signIn: { try await session.performSignIn() }
                    )
                    .padding(16)
                    .frame(width: 420)
                }

                Picker("Model", selection: Binding(get: { session.modelID }, set: { value in
                    if value == Self.customTag { isEnteringCustomModel = true } else { session.selectModel(value) }
                })) {
                    ForEach(session.modelOptions) { option in Text(option.label).tag(option.id) }
                    Divider()
                    Text("Custom model ID…").tag(Self.customTag)
                }
                .frame(maxWidth: 240)
                .accessibilityIdentifier("\(identifierPrefix)-model")

                Button {
                    Task { await session.loadModels(refresh: true) }
                } label: {
                    if session.isRefreshingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(session.isRefreshingModels)
                .help("Refresh the model list")
                .accessibilityLabel("Refresh models")

                Picker("Effort", selection: Binding(get: { session.effort }, set: { session.selectEffort($0) })) {
                    ForEach(session.effortChoices, id: \.self) { Text(SummaryEffortResolver.label(for: $0)).tag($0) }
                }
                .frame(maxWidth: 200)
                .accessibilityIdentifier("\(identifierPrefix)-effort")

                if showsInstructions {
                    Button {
                        showInstructions = true
                    } label: {
                        Label("Instructions", systemImage: session.customInstructions.isEmpty ? "text.bubble" : "text.bubble.fill")
                    }
                    .help(session.customInstructions.isEmpty ? "Add your own instructions" : "Edit your instructions")
                    .accessibilityIdentifier("kanban-summary-instructions-button")
                }
            }
            if session.connection == .chatGPTAccount, session.accountStatus == .signedOut {
                HStack(spacing: 6) {
                    Label("Codex isn't signed in to your ChatGPT account.", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Button(session.isSigningIn ? "Signing in…" : "Sign in…") { Task { await session.signIn() } }
                        .disabled(session.isSigningIn)
                }
                .font(.caption)
            }
            if let note = session.effortNote ?? session.modelRefreshError {
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let description = session.modelListDescription {
                Text(description).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .task { await session.refreshAccountStatus() }
        .alert("Custom model ID", isPresented: $isEnteringCustomModel) {
            TextField("e.g. gpt-6-sol or llama3.1:8b", text: $customModel)
            Button("Use") { session.useCustomModel(customModel); customModel = "" }
            Button("Cancel", role: .cancel) { customModel = "" }
        } message: {
            Text("Passed to Codex exactly as typed.")
        }
        .sheet(isPresented: $showInstructions) {
            VStack(alignment: .trailing, spacing: 12) {
                SummaryInstructionsEditor(
                    instructions: $session.customInstructions,
                    builtInRules: KanbanSummaryPrompt.instructions,
                    defaultInstructions: KanbanSummaryPrompt.defaultCustomInstructions,
                    instructionsLimit: KanbanSummaryPrompt.customInstructionsLimit
                )
                Button("Done") { showInstructions = false }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("kanban-summary-instructions-done")
            }
            .padding(20)
            .frame(width: 560)
        }
    }

    private static let customTag = "\u{0}custom"
}

// MARK: - Generating

private struct KanbanSummaryGeneratingOverlay: View {
    let session: KanbanSummarySession
    let startedAt: Date

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Generating with Codex · \(session.connection.label) · \(session.selectedModel.label)")
                    .font(.headline)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("\(Int(context.date.timeIntervalSince(startedAt)))s elapsed")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel) { session.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("kanban-summary-cancel")
            }
        }
    }
}

// MARK: - Result

private struct KanbanSummaryResultView: View {
    @Bindable var session: KanbanSummarySession
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Summary").font(.headline)
                Text("Edit freely before copying.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(copied ? Color.green : Color.accentColor)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help(copied ? "Copied" : "Copy summary to clipboard (⇧⌘C)")
                .accessibilityLabel(copied ? "Copied" : "Copy summary")
                .accessibilityIdentifier("kanban-summary-copy")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            TextEditor(text: $session.resultText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 16)
                .accessibilityIdentifier("kanban-summary-text")

            HStack {
                if let result = session.lastResult {
                    Text(footer(result)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Change selection") { session.changeSelection() }
                Button {
                    session.regenerate()
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("kanban-summary-regenerate")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func copy() {
        guard session.copyToPasteboard() else { return }
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func footer(_ result: SummaryResult) -> String {
        var parts = ["Codex", result.config.connection.label, result.resolvedModel ?? result.config.modelID ?? "CLI default model"]
        if let effort = result.config.effort { parts.append("effort \(effort)") }
        parts.append("\(Int(result.duration.components.seconds))s")
        return "Generated with " + parts.joined(separator: " · ")
    }
}

// MARK: - Error Banner

private struct KanbanSummaryErrorBanner: View {
    let presentation: SummaryErrorPresenter.Presentation
    let onDismiss: () -> Void
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title).font(.callout.weight(.semibold))
                        .accessibilityIdentifier("kanban-summary-error-title")
                    Text(.init(presentation.message)).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("kanban-summary-error-message")
                }
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
            if let details = presentation.details {
                Button(showDetails ? "Hide details" : "Show details") { showDetails.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityIdentifier("kanban-summary-error-details-toggle")
                if showDetails {
                    HStack(alignment: .top) {
                        Text(details)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("kanban-summary-error-details")
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(details, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy details")
                        .accessibilityLabel("Copy error details")
                    }
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
