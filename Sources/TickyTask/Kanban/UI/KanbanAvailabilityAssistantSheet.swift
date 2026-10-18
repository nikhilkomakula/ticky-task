import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// Sends only the reviewed request through the shared AI connection. The local plan owns
/// resolution and validation; Apply saves its single delta through KanbanService.
struct KanbanAvailabilityAssistantSheet: View {
    let project: KanbanProject
    let window: [KanbanDay]
    @State var images: [URL]
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \KanbanPerson.name) private var directory: [KanbanPerson]
    @State private var instructions = ""
    @State private var text = ""
    @State private var refine = ""
    @State private var phase = Phase.input
    @State private var rows: [KanbanAvailabilityAssistant.PlanRow] = []
    @State private var unresolved: [KanbanAvailabilityAssistant.Unresolved] = []
    @State private var warnings: [String] = []
    @State private var reviewed: KanbanAvailabilityAssistant.Snapshot?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var staging = KanbanAvailabilityStaging()
    @State private var session: KanbanSummarySession
    private let generator: SummaryGenerating

    enum Phase: Equatable { case input, extracting, review }

    init(project: KanbanProject, window: [KanbanDay], images: [URL]) {
        self.project = project
        self.window = window
        _images = State(initialValue: images)
        let dependencies = WeeklySummaryDependencies.make()
        generator = dependencies.generator
        _session = State(initialValue: KanbanSummarySession(generator: dependencies.generator, catalog: dependencies.catalog))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Update availability").font(.headline)
                Text("Describe a change, paste your team's list, or add screenshots. Review every suggestion before anything changes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            KanbanSummaryConfigurationBar(session: session, showsInstructions: false, identifierPrefix: "kanban-assistant")
                .disabled(phase == .extracting)
            switch phase {
            case .input: inputView
            case .extracting:
                VStack(spacing: 12) {
                    ProgressView("Reading the request…")
                    Button("Cancel") { task?.cancel(); phase = .input }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .review:
                if let reviewed { reviewView(reviewed) }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kanban-assistant-error")
            }
        }
        .padding(20)
        .frame(minWidth: 820, idealWidth: 960, minHeight: 680, idealHeight: 800)
        .task { await session.loadModels(); await session.refreshAccountStatus() }
        .onChange(of: scenePhase) { _, value in
            if value == .active { Task { await session.syncConnection() } }
        }
        .onDisappear {
            task?.cancel()
            staging.removeAll()
        }
    }

    // MARK: Input

    private var dateContext: KanbanAvailabilityAssistant.DateContext {
        let board = KanbanAvailability.Board(project)
        let start = board.start ?? window.first ?? KanbanDay.today().monday
        let end = board.end ?? (window.last ?? start).adding(days: 6)
        return .init(start: start, end: end, today: KanbanDay.today())
    }

    private var people: [KanbanAvailabilityAssistant.Person] {
        let members = Set(project.resources.filter { $0.archivedAt == nil }.compactMap { $0.person?.id })
        return directory.filter { $0.archivedAt == nil }.map {
            .init(id: $0.id, name: $0.name, initials: $0.initials, aliases: $0.aliases ?? [], onBoard: members.contains($0.id))
        }
    }

    private var hasInstructions: Bool { !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var imagesUnsupported: Bool {
        !images.isEmpty && KanbanAvailabilityAssistant.imageCapability(connection: session.connection, model: session.selectedModel) == .unsupported
    }

    private var inputView: some View {
        let range = dateContext
        return VStack(alignment: .leading, spacing: 10) {
            Text("Instructions").font(.callout.weight(.semibold))
            TextField("For example: cancel Ravi's PTO on Friday, or add Thanksgiving on 26 Nov", text: $instructions, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("kanban-assistant-instructions")
            Text("Material (optional)").font(.callout.weight(.semibold))
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 110)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste names and dates, e.g. “Ravi off 20–24 Oct, Mia out Wed afternoon”")
                            .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityIdentifier("kanban-assistant-text")
            HStack(spacing: 8) {
                Button("Paste image") { pasteImage() }
                Button("Choose files…") { chooseFiles() }
                Text("or drop screenshots here").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if !images.isEmpty { imageStrip }
            imageSupportNote
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dates: \(KanbanAvailabilityFormat.short(range.start)) – \(KanbanAvailabilityFormat.short(range.end)) (today \(KanbanAvailabilityFormat.short(range.today)))")
                    Text("People: \(people.filter(\.onBoard).map(\.name).joined(separator: ", "))")
                        .lineLimit(2)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(disclosure)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Suggest changes") { extract() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((!hasInstructions && !hasText && images.isEmpty) || imagesUnsupported)
                    .accessibilityIdentifier("kanban-assistant-extract")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let pictures = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            images += pictures
            return !pictures.isEmpty
        }
    }

    private var imageStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, url in
                    ZStack(alignment: .topTrailing) {
                        (NSImage(contentsOf: url).map { Image(nsImage: $0).resizable() } ?? Image(systemName: "photo").resizable())
                            .scaledToFit()
                            .frame(width: 120, height: 80)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                        Button { images.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove image \(index + 1)")
                    }
                    .help("image-\(index + 1): \(url.lastPathComponent)")
                }
            }
        }
        .frame(height: 90)
    }

    @ViewBuilder
    private var imageSupportNote: some View {
        if !images.isEmpty {
            switch KanbanAvailabilityAssistant.imageCapability(connection: session.connection, model: session.selectedModel) {
            case .supported: EmptyView()
            case .unknown:
                Label("Image support unknown for this model — an answer that ignores the screenshots can look complete; check the review.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("kanban-assistant-image-warning")
            case .unsupported:
                Label("This model does not support images. Choose another model or remove the screenshots to suggest changes.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("kanban-assistant-image-warning")
            }
        }
    }

    private var disclosure: String {
        let connection = session.connection
        let target: String
        if let address = connection.localBaseURL, let components = URLComponents(string: address), let host = components.host {
            target = "\(connection.label) at \(host)\(components.port.map { ":\($0)" } ?? "")"
        } else if connection.isLocal {
            target = "\(connection.label) (destination host unavailable; check its address in Settings › AI)"
        } else if connection == .cliConfiguration {
            target = "the provider in your Codex CLI configuration (destination host set there; check that configuration)"
        } else {
            target = "your ChatGPT account at chatgpt.com"
        }
        return "Suggest changes sends your instructions, the text and images shown, the date range, the board's people's names and aliases, and recorded time off, this board's overrides and public holidays within that range (including exceptions as names; no notes) through your installed Codex CLI to \(target). "
            + "The Codex CLI must be installed; an OpenAI-compatible server needs a Responses API. Everything visible in screenshots is included. No cards or other boards are sent. Nothing changes until you review and click Apply."
    }

    // MARK: Review

    private func reviewView(_ snapshot: KanbanAvailabilityAssistant.Snapshot) -> some View {
        let plan = try? KanbanAvailabilityAssistant.plan(for: rows, snapshot: snapshot, aliases: aliasMap())
        let clashing = KanbanAvailabilityAssistant.clashingSelection(rows)
        let count = plan.map { changeCount($0.delta) } ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            List {
                group("New", id: "new", statuses: [.new], snapshot: snapshot, plan: plan)
                group("Changes", id: "changes", statuses: [.changes, .overlaps], snapshot: snapshot, plan: plan)
                group("Removals", id: "removals", statuses: [.removals], snapshot: snapshot, plan: plan)
                group("Holidays (applies to everyone)", id: "holidays", statuses: [.holidays], snapshot: snapshot, plan: plan)
                group("Unmatched", id: "unmatched", statuses: [.unmatched], snapshot: snapshot, plan: plan)
                needsReviewGroup(snapshot, plan: plan)
                group("Already true", id: "already-true", statuses: [.alreadyRecorded], snapshot: snapshot, plan: plan)
                if !unresolved.isEmpty {
                    Section("Couldn't be read") {
                        ForEach(Array(unresolved.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.evidence.isEmpty ? "(no excerpt)" : item.evidence).font(.callout)
                                Text(item.issues.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !warnings.isEmpty {
                    Section("Notes from the assistant") { ForEach(warnings, id: \.self) { Text($0).font(.caption) } }
                }
            }
            .frame(minHeight: 300)
            .accessibilityIdentifier("kanban-assistant-review")
            HStack(spacing: 8) {
                TextField("Correct how it was read (e.g. “Ravi means Ravindra”, “those dates are in November”)", text: $refine)
                Button("Suggest changes") { extract() }
                    .disabled(refine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imagesUnsupported)
                    .help("Reads the same material again with your correction")
            }
            imageSupportNote
            if !clashing.isEmpty {
                Text("Two ticked suggestions disagree about the same person and days, week's override, or holiday. Untick one.")
                    .font(.callout).foregroundStyle(.red)
            } else if plan == nil {
                Text(planError(snapshot)).font(.callout).foregroundStyle(.red)
            }
            Text(plan?.impact ?? "Select the rows to apply.")
                .font(.callout)
                .accessibilityIdentifier("kanban-assistant-impact")
            Text(crossBoardDisclosure(plan)).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Back") { phase = .input }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply \(count) \(count == 1 ? "change" : "changes")") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0 || !clashing.isEmpty || plan == nil)
                    .accessibilityIdentifier("kanban-assistant-apply")
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, id: String, statuses: [KanbanAvailabilityAssistant.Status], snapshot: KanbanAvailabilityAssistant.Snapshot, plan: KanbanAvailabilityAssistant.Plan?) -> some View {
        let indices = rows.indices.filter { statuses.contains(rows[$0].status) }
        if !indices.isEmpty {
            Section(title) { ForEach(indices, id: \.self) { rowView($0, snapshot: snapshot, plan: plan) } }
                .accessibilityIdentifier("kanban-assistant-group-\(id)")
        }
    }

    @ViewBuilder
    private func needsReviewGroup(_ snapshot: KanbanAvailabilityAssistant.Snapshot, plan: KanbanAvailabilityAssistant.Plan?) -> some View {
        let indices = rows.indices.filter { if case .needsReview = rows[$0].status { true } else { false } }
        if !indices.isEmpty {
            Section("Needs review") { ForEach(indices, id: \.self) { rowView($0, snapshot: snapshot, plan: plan) } }
                .accessibilityIdentifier("kanban-assistant-group-needs-review")
        }
    }

    private func rowView(_ index: Int, snapshot: KanbanAvailabilityAssistant.Snapshot, plan: KanbanAvailabilityAssistant.Plan?) -> some View {
        let row = rows[index]
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: $rows[index].selected)
                .labelsHidden()
                .disabled(!row.isApplicable)
                .accessibilityLabel(row.accessibilityLabel(snapshot: snapshot))
            VStack(alignment: .leading, spacing: 3) {
                Label(row.title, systemImage: rowSymbol(row)).font(.callout.weight(.semibold))
                if let detail = row.detail(snapshot: snapshot) { Text(detail).font(.caption).foregroundStyle(.secondary) }
                if row.operations.contains(where: { $0.personText != nil }) { personPicker(index, snapshot: snapshot) }
                holidayPicker(index, snapshot: snapshot)
                ForEach(Array(row.operations.enumerated()), id: \.offset) { _, operation in
                    Text("“\(operation.evidence)”").font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
                }
                if case let .needsReview(reason) = row.status {
                    Text(reason).font(.caption).foregroundStyle(KanbanAvailabilityPalette.text(.yellow))
                }
                if row.offBoard { Text("Not on this board: tick to include their time off.").font(.caption).foregroundStyle(.secondary) }
                rowPreview(row, snapshot: snapshot, planned: plan?.previews[row.id])
            }
            Spacer(minLength: 0)
        }
    }

    private func rowSymbol(_ row: KanbanAvailabilityAssistant.PlanRow) -> String {
        switch row.status {
        case .removals, .changes, .overlaps, .holidays: "minus.circle"
        case .alreadyRecorded: "checkmark.circle"
        case .unmatched, .needsReview: "exclamationmark.circle"
        case .new: "plus.circle"
        }
    }

    @ViewBuilder
    private func rowPreview(_ row: KanbanAvailabilityAssistant.PlanRow, snapshot: KanbanAvailabilityAssistant.Snapshot, planned: KanbanAvailabilityAssistant.RowPreview?) -> some View {
        let preview = planned ?? independentPreview(for: row, snapshot: snapshot)
        if let preview {
            if !preview.removed.isEmpty {
                Text("Removes: \(preview.removed.map(describe).joined(separator: "; "))").font(.caption)
                Text("Keeps: \(preview.kept.isEmpty ? "nothing else" : preview.kept.map(describe).joined(separator: "; "))").font(.caption)
            }
            if !preview.holidaysBefore.isEmpty {
                Text("Changes: \(preview.holidaysBefore.map(describeHoliday).joined(separator: "; ")) → \(preview.holidaysAfter.isEmpty ? "removed" : preview.holidaysAfter.map(describeHoliday).joined(separator: "; "))")
                    .font(.caption)
            }
            ForEach(Array(preview.weeks.enumerated()), id: \.offset) { _, week in
                Text("\(personName(week.personID)) · \(KanbanAvailabilityFormat.week(week.week)): \(days(week.before)) → \(days(week.after)) days")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func independentPreview(for row: KanbanAvailabilityAssistant.PlanRow, snapshot: KanbanAvailabilityAssistant.Snapshot) -> KanbanAvailabilityAssistant.RowPreview? {
        var selected = row
        selected.selected = true
        return (try? KanbanAvailabilityAssistant.plan(for: [selected], snapshot: snapshot, aliases: aliasMap()))?.previews[row.id]
    }

    private func personPicker(_ index: Int, snapshot: KanbanAvailabilityAssistant.Snapshot) -> some View {
        let row = rows[index]
        var suggestions: [UUID] = []
        if case let .unmatched(ids) = row.match { suggestions = ids }
        let suggested = people.filter { suggestions.contains($0.id) }
        let onBoard = people.filter(\.onBoard)
        let others = people.filter { !$0.onBoard }
        let names = row.operations.compactMap(\.personText).reduce(into: [String]()) { names, name in
            if !names.contains(name) { names.append(name) }
        }
        return HStack(spacing: 6) {
            Text(names.isEmpty ? "Person" : names.joined(separator: " / "))
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
            Menu(row.personID.map(personName) ?? "Choose…") {
                if !suggested.isEmpty {
                    Section("Suggested") { ForEach(suggested, id: \.id) { p in Button(p.name) { choose(p.id, for: index, snapshot: snapshot) } } }
                }
                Section("On this board") { ForEach(onBoard, id: \.id) { p in Button(p.name) { choose(p.id, for: index, snapshot: snapshot) } } }
                if !others.isEmpty {
                    Section("Other people") { ForEach(others, id: \.id) { p in Button(p.name) { choose(p.id, for: index, snapshot: snapshot) } } }
                }
            }
            .fixedSize()
            .accessibilityIdentifier("kanban-assistant-person-\(index)")
            if !row.namesToRemember.isEmpty {
                Toggle("Remember this name", isOn: $rows[index].rememberName).font(.caption).toggleStyle(.checkbox)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func holidayPicker(_ index: Int, snapshot: KanbanAvailabilityAssistant.Snapshot) -> some View {
        let row = rows[index]
        let target = row.operations.first { $0.kind == .removeHoliday || $0.kind == .holidayException }
        let candidates = target.map { KanbanAvailabilityAssistant.holidayCandidates($0, snapshot: snapshot) } ?? []
        if candidates.count > 1 {
            Picker("Holiday", selection: Binding(get: { rows[index].holidayID }, set: { id in
                rows[index].holidayID = id
                refreshStatus(index, snapshot: snapshot)
            })) {
                Text("Choose…").tag(Optional<UUID>.none)
                ForEach(candidates, id: \.id) { holiday in Text(describeHoliday(holiday)).tag(Optional(holiday.id)) }
            }
            .accessibilityIdentifier("kanban-assistant-holiday-\(index)")
        }
    }

    private func choose(_ id: UUID, for index: Int, snapshot: KanbanAvailabilityAssistant.Snapshot) {
        KanbanAvailabilityAssistant.choosePerson(id, for: &rows[index], people: people, snapshot: snapshot)
    }

    private func refreshStatus(_ index: Int, snapshot: KanbanAvailabilityAssistant.Snapshot) {
        rows[index].status = KanbanAvailabilityAssistant.reviewStatus(of: rows[index], snapshot: snapshot, context: dateContext)
        rows[index].selected = rows[index].status == .new && !rows[index].offBoard
    }

    private func personName(_ id: UUID) -> String { people.first { $0.id == id }?.name ?? "Person" }
    private func days(_ halfDays: Int) -> String { halfDays.isMultiple(of: 2) ? "\(halfDays / 2)" : "\(halfDays / 2).5" }
    private func describe(_ entry: KanbanTimeOffDTO) -> String {
        "\(entry.personId.map(personName) ?? "Person") · \(KanbanService.span(entry)) \(KanbanTimeOffKind(rawValue: entry.kindRaw)?.label ?? "")"
    }
    private func describeHoliday(_ holiday: KanbanHolidayDTO) -> String {
        let date = KanbanDay(key: holiday.day).map(KanbanAvailabilityFormat.short) ?? holiday.day
        let portion = KanbanTimeOffPortion(rawValue: holiday.portionRaw)?.label ?? holiday.portionRaw
        let names = (holiday.workedBy ?? []).map { id in
            directory.first { $0.id == id }?.name ?? "Person \(id.uuidString.prefix(8))"
        }.sorted()
        return "\(holiday.name) · \(date) · \(portion) · works: \(names.isEmpty ? "nobody" : names.joined(separator: ", "))"
    }
    private func changeCount(_ delta: KanbanAvailabilityDelta) -> Int {
        delta.timeOff.count + delta.overrides.count + delta.holidays.count + delta.aliases.count
    }
    private func crossBoardDisclosure(_ plan: KanbanAvailabilityAssistant.Plan?) -> String {
        guard let plan else { return "Time off counts on every board they're on." }
        let people = Set(plan.delta.timeOff.flatMap { [$0.before?.personId, $0.after?.personId].compactMap { $0 } })
        let count = boardCount(people)
        return "Time off counts on every board they're on.\(people.isEmpty ? "" : " Selected time off affects \(count) \(count == 1 ? "board" : "boards").")"
    }
    private func planError(_ snapshot: KanbanAvailabilityAssistant.Snapshot) -> String {
        do {
            _ = try KanbanAvailabilityAssistant.plan(for: rows, snapshot: snapshot, aliases: aliasMap())
            return ""
        } catch { return error.localizedDescription }
    }

    // MARK: Actions

    private func extract() {
        error = nil
        if session.syncPreferences() { Task { await session.loadModels() } }
        guard !imagesUnsupported else { return }
        task?.cancel()
        let material = text
        let pictures = images
        let range = dateContext
        let scope = people
        let ownerInstructions = instructions
        let correction = phase == .review ? refine : nil
        let snapshot: KanbanAvailabilityAssistant.Snapshot
        do { snapshot = try readSnapshot() }
        catch { self.error = error.localizedDescription; return }
        let request = SummaryRequest(
            instructions: KanbanAvailabilityAssistant.instructions(refine: correction, ownerInstructions: ownerInstructions),
            payload: KanbanAvailabilityAssistant.payload(text: material, imageCount: pictures.count, context: range,
                                                        people: scope.filter(\.onBoard), snapshot: snapshot),
            config: SummaryRunConfig(connection: session.connection, modelID: session.modelID.isEmpty ? nil : session.modelID,
                                     effort: session.effort.cliValue),
            images: pictures, payloadLabel: KanbanAvailabilityAssistant.payloadLabel)
        phase = .extracting
        task = Task {
            do {
                let result = try await generator.generate(request)
                guard !Task.isCancelled else { return }
                let extraction = try KanbanAvailabilityAssistant.parse(result.text, imageCount: pictures.count,
                    hasText: !material.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    hasInstructions: !ownerInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || correction != nil)
                try KanbanAvailabilityAssistant.requireCurrent(snapshot, current: readSnapshot())
                reviewed = snapshot
                rows = KanbanAvailabilityAssistant.review(extraction, people: scope, snapshot: snapshot, context: range)
                unresolved = extraction.unresolved
                warnings = extraction.warnings
                phase = .review
            } catch is CancellationError {
                if !Task.isCancelled { phase = .input }
            } catch let failure as WeeklySummaryError {
                guard !Task.isCancelled else { return }
                let shown = SummaryErrorPresenter.present(failure, connection: request.config.connection)
                error = "\(shown.title). \(shown.message)"
                phase = .input
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                phase = .input
            }
        }
    }

    private func apply() {
        guard let reviewed else { return }
        do {
            try KanbanAvailabilityAssistant.requireCurrent(reviewed, current: readSnapshot())
            let plan = try KanbanAvailabilityAssistant.plan(for: rows, snapshot: reviewed, aliases: aliasMap())
            guard !plan.delta.isEmpty else { return }
            try app.kanbanService(context).applyAvailability(plan.delta, on: project, summary: "Updated availability: \(plan.impact)")
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func readSnapshot() throws -> KanbanAvailabilityAssistant.Snapshot {
        let timeOff = try context.fetch(FetchDescriptor<KanbanTimeOff>()).map(KanbanTimeOffDTO.init)
        let holidays = try context.fetch(FetchDescriptor<KanbanHoliday>()).map(KanbanHolidayDTO.init)
        return .init(project: project, timeOff: timeOff, holidays: holidays)
    }
    private func aliasMap() -> [UUID: [String]] {
        Dictionary(directory.compactMap { p in p.aliases.map { (p.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }
    private func boardCount(_ people: Set<UUID>) -> Int {
        Set(directory.filter { people.contains($0.id) }.flatMap { $0.memberships.filter { $0.archivedAt == nil }.compactMap { $0.project?.id } }).count
    }
    private func pasteImage() {
        guard let image = NSImage(pasteboard: .general), let url = staging.write(image) else {
            error = "There's no image on the clipboard."
            return
        }
        images.append(url)
    }
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { images += panel.urls }
    }
}

/// Pasted screenshots, written to a private folder under Caches for the CLI to read, and removed
/// when the sheet closes (and at the next launch after a crash).
struct KanbanAvailabilityStaging {
    static var root: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.tickytask.mac")
            .appendingPathComponent("availability-input", isDirectory: true)
    }

    let folder = KanbanAvailabilityStaging.root.appendingPathComponent(UUID().uuidString, isDirectory: true)

    func write(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("pasted-\(UUID().uuidString.prefix(8)).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    func removeAll() { try? FileManager.default.removeItem(at: folder) }

    static func removeStale() {
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: entry) }
    }
}
