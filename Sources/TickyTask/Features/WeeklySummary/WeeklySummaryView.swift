import SwiftUI
import SwiftData

/// The Weekly Summary sheet: pick tasks day by day, choose Claude/Codex + model
/// + effort, generate one overall update, then edit and copy it.
struct WeeklySummaryView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("weekStartsMonday") private var weekStartsMonday = true
    @Query(sort: [SortDescriptor(\TaskItem.sortIndex)]) private var allTasks: [TaskItem]
    @Bindable var session: WeeklySummarySession

    private var weekDays: [Date] {
        SummaryWeek.days(containing: session.weekAnchor, weekStartsMonday: weekStartsMonday)
    }

    /// The week's day-task rows as immutable snapshots (custom-list tasks excluded).
    private var weekTasks: [SummaryTaskSnapshot] {
        let keys = Set(weekDays.map { WeekMath.dayKey(for: $0) })
        return allTasks
            .filter { task in task.dayKey.map(keys.contains) ?? false }
            .map(SummaryTaskSnapshot.init)
    }

    var body: some View {
        let tasks = weekTasks
        VStack(spacing: 0) {
            header
            Divider()
            if let presentation = session.errorPresentation {
                SummaryErrorBanner(presentation: presentation, onDismiss: session.dismissError)
                    .padding([.horizontal, .top], 12)
            }
            switch session.phase {
            case .result:
                SummaryResultView(session: session)
            case .selecting, .generating:
                SummarySelectionView(session: session, days: weekDays, tasks: tasks)
                    .disabled(session.isGenerating)
                    .overlay {
                        if case .generating(let startedAt) = session.phase {
                            SummaryGeneratingOverlay(session: session, startedAt: startedAt)
                        }
                    }
            }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 620, idealHeight: 700)
        .task { await session.loadModels() }
        .onDisappear { session.cancel() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.badge.star").foregroundStyle(.secondary)
            Text("Weekly Summary").font(.headline)
            Spacer()
            if session.phase != .result {
                Button { session.shiftWeek(by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Previous week")
                    .disabled(session.isGenerating)
                Text(rangeLabel)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .accessibilityIdentifier("summary-week-range")
                Button { session.shiftWeek(by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .help("Next week")
                    .disabled(session.isGenerating)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(session.isGenerating)
                .accessibilityIdentifier("summary-done")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var rangeLabel: String {
        guard let first = weekDays.first, let last = weekDays.last else { return "" }
        return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day().year()))"
    }
}

// MARK: - Selection

private struct SummarySelectionView: View {
    @Bindable var session: WeeklySummarySession
    let days: [Date]
    let tasks: [SummaryTaskSnapshot]

    private var selectedCount: Int { tasks.filter { session.selectedIDs.contains($0.id) }.count }
    private var selectedWithNotes: Int { tasks.filter { session.selectedIDs.contains($0.id) && $0.hasNotes }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose the tasks whose notes to include in one overall update.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select all with notes") { session.selectAllWithNotes(in: tasks) }
                    .disabled(!tasks.contains(where: \.hasNotes))
                    .accessibilityIdentifier("summary-select-notes")
                Button("Clear") { session.clearSelection() }
                    .disabled(session.selectedIDs.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if tasks.isEmpty {
                ContentUnavailableView("No tasks this week", systemImage: "calendar",
                                       description: Text("Choose another week with the arrows above."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(days, id: \.self) { day in
                            let key = WeekMath.dayKey(for: day)
                            SummaryDaySection(session: session, day: day,
                                              dayTasks: ordered(tasks.filter { $0.dayKey == key }),
                                              weekTasks: tasks)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }

            Divider()
            SummaryConfigurationBar(session: session)
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedCount) selected · \(selectedWithNotes) with notes")
                        .font(.callout.weight(.medium))
                        .accessibilityIdentifier("summary-selection-count")
                    Text("Sends the selected tasks through your \(session.provider.cliName) to its configured model provider. Your CLI and provider settings apply. Summarizes current notes and statuses, not a history of the week.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    session.generate(weekTasks: tasks)
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canGenerate(weekTasks: tasks))
                .help(session.canGenerate(weekTasks: tasks) ? "Generate the summary" : "Select at least one task that has notes")
                .accessibilityIdentifier("summary-generate")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func ordered(_ rows: [SummaryTaskSnapshot]) -> [SummaryTaskSnapshot] {
        rows.sorted { $0.sortIndex != $1.sortIndex ? $0.sortIndex < $1.sortIndex : $0.id.uuidString < $1.id.uuidString }
    }
}

private struct SummaryDaySection: View {
    @Bindable var session: WeeklySummarySession
    let day: Date
    let dayTasks: [SummaryTaskSnapshot]
    let weekTasks: [SummaryTaskSnapshot]

    private var selectedHere: Int { dayTasks.filter { session.selectedIDs.contains($0.id) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if !dayTasks.isEmpty {
                    Button {
                        session.setDay(dayTasks, selected: selectedHere < dayTasks.count)
                    } label: {
                        Image(systemName: selectedHere == 0 ? "square" : (selectedHere == dayTasks.count ? "checkmark.square.fill" : "minus.square.fill"))
                            .foregroundStyle(selectedHere == 0 ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(selectedHere < dayTasks.count ? "Select all tasks on this day" : "Deselect this day")
                    .accessibilityLabel("Select day")
                }
                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.subheadline.weight(.semibold))
                if selectedHere > 0 {
                    Text("\(selectedHere) selected").font(.caption).foregroundStyle(.secondary)
                }
            }
            if dayTasks.isEmpty {
                Text("No tasks").font(.caption).foregroundStyle(.tertiary).padding(.leading, 26)
            } else {
                ForEach(dayTasks) { task in
                    SummaryTaskRow(session: session, task: task,
                                   seriesCount: task.seriesID.map { id in weekTasks.filter { $0.seriesID == id }.count } ?? 0,
                                   weekTasks: weekTasks)
                }
            }
        }
    }
}

private struct SummaryTaskRow: View {
    @Bindable var session: WeeklySummarySession
    let task: SummaryTaskSnapshot
    let seriesCount: Int
    let weekTasks: [SummaryTaskSnapshot]

    private var isSelected: Bool { session.selectedIDs.contains(task.id) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(task.title.isEmpty ? "Untitled" : task.title)
                        .strikethrough(task.isDone)
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                    if task.isDone {
                        Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                            .accessibilityLabel("Done")
                    }
                    if task.isRecurring {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Repeats")
                    }
                }
                Text(task.hasNotes ? excerpt : "No notes")
                    .font(.caption)
                    .foregroundStyle(task.hasNotes ? .secondary : .tertiary)
                    .lineLimit(2)
            }
            Spacer()
            if let series = task.seriesID, seriesCount > 1 {
                Button("Select series (\(seriesCount))") { session.selectSeries(series, in: weekTasks) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Select every occurrence of this repeating task in this week")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { session.toggle(task.id) }
        .padding(.leading, 18)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isSelected ? "selected" : "not selected")
        .accessibilityIdentifier("summary-task-\(task.title)")
    }

    private var excerpt: String {
        task.notes.plainText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Provider / model / effort

private struct SummaryConfigurationBar: View {
    @Bindable var session: WeeklySummarySession
    @State private var isEnteringCustomModel = false
    @State private var customModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("Provider", selection: Binding(get: { session.provider }, set: { session.selectProvider($0) })) {
                    ForEach(SummaryProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("summary-provider")

                Picker("Model", selection: Binding(get: { session.modelID }, set: { value in
                    if value == Self.customTag { isEnteringCustomModel = true } else { session.selectModel(value) }
                })) {
                    ForEach(session.modelOptions) { option in Text(option.label).tag(option.id) }
                    Divider()
                    Text("Custom model ID…").tag(Self.customTag)
                }
                .frame(maxWidth: 260)
                .accessibilityIdentifier("summary-model")

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
                .help(session.provider == .claude ? "Refresh configured models" : "Refresh the Codex model list")
                .accessibilityLabel("Refresh models")
                .accessibilityIdentifier("summary-refresh-models")

                Picker("Effort", selection: Binding(get: { session.effort }, set: { session.selectEffort($0) })) {
                    ForEach(session.effortChoices, id: \.self) { Text(SummaryEffortResolver.label(for: $0)).tag($0) }
                }
                .frame(maxWidth: 220)
                .accessibilityIdentifier("summary-effort")
            }
            if let note = session.effortNote ?? session.modelRefreshError {
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            } else if let description = session.modelListDescription {
                Text(description).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .alert("Custom model ID", isPresented: $isEnteringCustomModel) {
            TextField("e.g. claude-opus-5-5 or gpt-6-sol", text: $customModel)
            Button("Use") { session.useCustomModel(customModel); customModel = "" }
            Button("Cancel", role: .cancel) { customModel = "" }
        } message: {
            Text("Passed to the \(session.provider.cliName) exactly as typed.")
        }
    }

    private static let customTag = "\u{0}custom"
}

// MARK: - Generating

private struct SummaryGeneratingOverlay: View {
    let session: WeeklySummarySession
    let startedAt: Date

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Generating with \(session.provider.displayName) · \(session.selectedModel.label)")
                    .font(.headline)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("\(Int(context.date.timeIntervalSince(startedAt)))s elapsed")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel) { session.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("summary-cancel")
            }
        }
    }
}

// MARK: - Result

private struct SummaryResultView: View {
    @Bindable var session: WeeklySummarySession
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
                .accessibilityIdentifier("summary-copy")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            TextEditor(text: $session.resultText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 16)
                .accessibilityIdentifier("summary-text")

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
                .accessibilityIdentifier("summary-regenerate")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .overlay {
            if case .generating(let startedAt) = session.phase {
                SummaryGeneratingOverlay(session: session, startedAt: startedAt)
            }
        }
    }

    private func copy() {
        guard session.copyToPasteboard() else { return }
        copied = true
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Copied", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func footer(_ result: SummaryResult) -> String {
        var parts = [result.config.provider.displayName, result.resolvedModel ?? result.config.modelID ?? "CLI default model"]
        if let effort = result.config.effort { parts.append("effort \(effort)") }
        parts.append("\(Int(result.duration.components.seconds))s")
        return "Generated with " + parts.joined(separator: " · ")
    }
}

// MARK: - Errors

private struct SummaryErrorBanner: View {
    let presentation: SummaryErrorPresenter.Presentation
    let onDismiss: () -> Void
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title).font(.callout.weight(.semibold))
                        .accessibilityIdentifier("summary-error-title")
                    Text(.init(presentation.message)).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("summary-error-message")
                }
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
            if let details = presentation.details {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    HStack(alignment: .top) {
                        Text(details)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(details, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy details")
                        .accessibilityLabel("Copy error details")
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("summary-error")
    }
}
