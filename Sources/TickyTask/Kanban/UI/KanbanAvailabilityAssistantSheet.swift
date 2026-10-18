import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// Update availability (design 03): paste text or add screenshots (e.g. of a Slack PTO canvas),
/// let Codex propose time off through the summaries' isolated connection, review every row,
/// then Apply them as one undoable change. Nothing is sent until Extract, nothing saved until
/// Apply; screenshots are staged in a private folder and removed when the sheet closes.
struct KanbanAvailabilityAssistantSheet: View {
    let project: KanbanProject
    let window: [KanbanDay]
    @State var images: [URL]
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \KanbanPerson.name) private var directory: [KanbanPerson]
    @State private var text = ""
    @State private var refine = ""
    @State private var phase = Phase.input
    @State private var rows: [KanbanAvailabilityAssistant.Row] = []
    @State private var unresolved: [KanbanAvailabilityAssistant.Unresolved] = []
    @State private var warnings: [String] = []
    /// The recorded time off the rows were reviewed against; Apply refuses if it has changed.
    @State private var reviewed: [KanbanTimeOffDTO] = []
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var staging = KanbanAvailabilityStaging()

    enum Phase: Equatable { case input, extracting, review }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Update availability").font(.headline)
                Text("Paste your team's PTO list (text or screenshots). Codex suggests time off; you review it before anything changes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            switch phase {
            case .input: inputView
            case .extracting:
                VStack(spacing: 12) {
                    ProgressView("Reading the material…")
                    Button("Cancel") { task?.cancel(); phase = .input }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .review: reviewView
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kanban-assistant-error")
            }
        }
        .padding(20)
        .frame(minWidth: 820, idealWidth: 960, minHeight: 560, idealHeight: 680)
        .onDisappear {
            task?.cancel()
            staging.removeAll()
        }
    }

    // MARK: Input

    private var context_: KanbanAvailabilityAssistant.DateContext {
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

    private var inputView: some View {
        let range = context_
        return VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 150)
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
            if !images.isEmpty {
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
                Button("Extract with Codex") { extract() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty)
                    .accessibilityIdentifier("kanban-assistant-extract")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let pictures = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            images += pictures
            return !pictures.isEmpty
        }
    }

    private var disclosure: String {
        let connection = KanbanSummaryPreferences().connection
        let target = connection == .cliConfiguration ? "the provider in your Codex configuration" : connection.label
        return "Extract sends the text and images shown, the date range and the board's people's names through your installed Codex CLI to \(target). "
            + "Names, PTO dates and everything visible in the screenshots are included. No other boards, cards or files are sent. "
            + "Codex only suggests entries; nothing changes until you review them and click Apply."
    }

    // MARK: Review

    private var reviewView: some View {
        let timeOff = reviewed
        let change = KanbanAvailabilityAssistant.change(for: rows, timeOff: timeOff, aliases: aliasMap())
        let boards = boardCount(change.people)
        let clashing = KanbanAvailabilityAssistant.clashingSelection(rows)
        return VStack(alignment: .leading, spacing: 8) {
            List {
                group("New", .new, timeOff)
                group("Overlaps recorded time off: replaces only these days", .overlaps, timeOff)
                group("Name not matched: pick the person", .unmatched, timeOff)
                needsReviewGroup(timeOff)
                group("Already recorded", .alreadyRecorded, timeOff)
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
                    Section("Notes from Codex") { ForEach(warnings, id: \.self) { Text($0).font(.caption) } }
                }
            }
            .frame(minHeight: 300)
            .accessibilityIdentifier("kanban-assistant-review")
            HStack(spacing: 8) {
                TextField("Correct how it was read (e.g. “Ravi means Ravindra”, “those dates are in November”)", text: $refine)
                Button("Refine") { extract() }
                    .disabled(refine.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Runs Codex again on the same material with your correction")
            }
            if !clashing.isEmpty {
                Text("Two ticked suggestions cover the same days for \(Set(clashing.map(\.candidate.personText)).sorted().joined(separator: ", ")). Untick one.")
                    .font(.callout).foregroundStyle(.red)
            }
            Text(change.added == 0 ? "Select the rows to apply."
                 : "Adds \(change.added) \(change.added == 1 ? "entry" : "entries")\(change.changed > 0 ? " and changes \(change.changed) recorded" : "") for \(change.people.count) \(change.people.count == 1 ? "person" : "people") across \(boards) \(boards == 1 ? "board" : "boards"). Time off counts on every board they're on.")
                .font(.callout)
                .accessibilityIdentifier("kanban-assistant-impact")
            HStack {
                Button("Back") { phase = .input }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply \(change.added) \(change.added == 1 ? "change" : "changes")") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(change.added == 0 || !clashing.isEmpty)
                    .accessibilityIdentifier("kanban-assistant-apply")
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ status: KanbanAvailabilityAssistant.Status, _ timeOff: [KanbanTimeOffDTO]) -> some View {
        let indices = rows.indices.filter { rows[$0].status == status }
        if !indices.isEmpty {
            Section(title) { ForEach(indices, id: \.self) { rowView($0, timeOff) } }
        }
    }

    @ViewBuilder
    private func needsReviewGroup(_ timeOff: [KanbanTimeOffDTO]) -> some View {
        let indices = rows.indices.filter { if case .needsReview = rows[$0].status { true } else { false } }
        if !indices.isEmpty {
            Section("Needs review: can't be applied as read") { ForEach(indices, id: \.self) { rowView($0, timeOff) } }
        }
    }

    private func rowView(_ index: Int, _ timeOff: [KanbanTimeOffDTO]) -> some View {
        let row = rows[index]
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: $rows[index].selected)
                .labelsHidden()
                .disabled(!row.isApplicable)
                .accessibilityLabel("Apply \(row.candidate.personText), \(span(row.candidate))")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.candidate.personText).font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    personPicker(index, timeOff)
                }
                Text("“\(row.candidate.evidence)”").font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
                if case let .needsReview(reason) = row.status { Text(reason).font(.caption).foregroundStyle(KanbanAvailabilityPalette.text(.yellow)) }
                if row.offBoard { Text("Not on this board: tick to include their time off.").font(.caption).foregroundStyle(.secondary) }
                if row.clash { Text("Covers the same days as another suggestion for this person: tick only one.").font(.caption).foregroundStyle(.red) }
                if row.status == .overlaps {
                    let preview = KanbanAvailabilityAssistant.preview(of: row, timeOff: timeOff)
                    Text("Replaces: \(preview.replaced.map(describe).joined(separator: "; "))").font(.caption).foregroundStyle(.secondary)
                    Text("Keeps: \(preview.kept.isEmpty ? "nothing else" : preview.kept.map(describe).joined(separator: "; "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(span(row.candidate)).monospacedDigit()
                Text("\(row.candidate.kind.label)\(row.candidate.confidence == "high" ? "" : " · \(row.candidate.confidence) confidence")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func personPicker(_ index: Int, _ timeOff: [KanbanTimeOffDTO]) -> some View {
        let row = rows[index]
        var suggestions: [UUID] = []
        if case let .unmatched(ids) = row.match { suggestions = ids }
        let onBoard = people.filter(\.onBoard)
        let others = people.filter { !$0.onBoard }
        return HStack(spacing: 6) {
            Menu(row.personID.flatMap { id in people.first { $0.id == id }?.name } ?? "Choose…") {
                let suggested = people.filter { suggestions.contains($0.id) }
                if !suggested.isEmpty {
                    Section("Suggested") { ForEach(suggested, id: \.id) { p in Button(p.name) { choose(p.id, for: index, timeOff) } } }
                }
                Section("On this board") { ForEach(onBoard, id: \.id) { p in Button(p.name) { choose(p.id, for: index, timeOff) } } }
                if !others.isEmpty {
                    Section("Other people") { ForEach(others, id: \.id) { p in Button(p.name) { choose(p.id, for: index, timeOff) } } }
                }
            }
            .fixedSize()
            .accessibilityIdentifier("kanban-assistant-person-\(index)")
            if row.personID != nil, row.match != .person(row.personID!) {
                Toggle("Remember this name", isOn: $rows[index].rememberName).font(.caption).toggleStyle(.checkbox)
            }
        }
    }

    /// Picking someone is an explicit choice, so it includes them even when they're not on the board.
    private func choose(_ id: UUID, for index: Int, _ timeOff: [KanbanTimeOffDTO]) {
        rows[index].personID = id
        rows[index].offBoard = !(people.first { $0.id == id }?.onBoard ?? false)
        rows[index].status = KanbanAvailabilityAssistant.status(of: rows[index], timeOff: timeOff)
        KanbanAvailabilityAssistant.markClashes(&rows)
        rows[index].selected = rows[index].status == .new && !rows[index].clash
    }

    private func describe(_ entry: KanbanTimeOffDTO) -> String {
        "\(KanbanService.span(entry)) \(KanbanTimeOffKind(rawValue: entry.kindRaw)?.label ?? "")"
    }

    private func span(_ c: KanbanAvailabilityAssistant.Candidate) -> String {
        KanbanService.span(KanbanTimeOffDTO(personId: nil, startDay: c.start.key, endDay: c.end.key, portion: c.portion, kind: c.kind))
    }

    // MARK: Actions

    private func extract() {
        error = nil
        let material = text
        let pictures = images
        let range = context_
        let scope = people
        let instructions = KanbanAvailabilityAssistant.instructions(refine: phase == .review ? refine : nil)
        let preferences = KanbanSummaryPreferences()
        let connection = preferences.connection
        let model = preferences.modelID(for: connection)
        let request = SummaryRequest(
            instructions: instructions,
            payload: KanbanAvailabilityAssistant.payload(text: material, imageCount: pictures.count, context: range, people: scope.filter(\.onBoard)),
            config: SummaryRunConfig(connection: connection, modelID: model.isEmpty ? nil : model,
                                     effort: preferences.effort(for: connection, modelID: model)?.cliValue),
            images: pictures, payloadLabel: KanbanAvailabilityAssistant.payloadLabel)
        let generator = WeeklySummaryDependencies.make().generator
        phase = .extracting
        task = Task {
            do {
                let result = try await generator.generate(request)
                let extraction = try KanbanAvailabilityAssistant.parse(result.text, imageCount: pictures.count,
                                                                         hasText: !material.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                guard !Task.isCancelled else { return }
                reviewed = allTimeOff()
                rows = KanbanAvailabilityAssistant.review(extraction, people: scope, timeOff: reviewed)
                unresolved = extraction.unresolved
                warnings = extraction.warnings
                phase = .review
            } catch is CancellationError {
                phase = .input
            } catch let failure as WeeklySummaryError {
                let shown = SummaryErrorPresenter.present(failure, connection: connection)
                error = "\(shown.title). \(shown.message)"
                phase = .input
            } catch {
                self.error = error.localizedDescription
                phase = rows.isEmpty ? .input : .review
            }
        }
    }

    private func apply() {
        // If time off changed since the review (here or on another board), review again rather
        // than overwrite it.
        let now = allTimeOff()
        if Set(now) != Set(reviewed) {
            reviewed = now
            for index in rows.indices {
                rows[index].status = KanbanAvailabilityAssistant.status(of: rows[index], timeOff: now)
                rows[index].selected = false
            }
            KanbanAvailabilityAssistant.markClashes(&rows)
            error = "Recorded time off changed since you reviewed these. Check the rows and tick them again."
            return
        }
        let change = KanbanAvailabilityAssistant.change(for: rows, timeOff: reviewed, aliases: aliasMap())
        do {
            try app.kanbanService(context).applyAvailability(change.delta, on: project,
                summary: "Updated availability: \(change.added) time-off \(change.added == 1 ? "entry" : "entries") for \(change.people.count) \(change.people.count == 1 ? "person" : "people")")
            dismiss()
        } catch {
            self.error = error.localizedDescription
            rows = rows.map { row in
                var row = row
                row.status = KanbanAvailabilityAssistant.status(of: row, timeOff: allTimeOff())
                return row
            }
        }
    }

    private func allTimeOff() -> [KanbanTimeOffDTO] {
        ((try? context.fetch(FetchDescriptor<KanbanTimeOff>())) ?? []).map(KanbanTimeOffDTO.init)
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
