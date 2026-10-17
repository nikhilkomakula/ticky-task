import SwiftUI
import SwiftData

/// Manages board labels or default labels for new boards: add, rename, recolor, symbol, reorder, delete.
/// Changes are staged in the sheet and applied atomically on Done.
struct KanbanLabelManagerSheet: View {
    enum Mode {
        case project(KanbanProject)
        case defaults
    }

    let mode: Mode
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var draft: KanbanLabelCatalogDraft
    @State private var editingID: UUID?
    @State private var editName = ""
    @State private var editColor = Color.gray
    @State private var editSymbolName: String? = nil
    @State private var error: String?
    @State private var deleteConfirmID: UUID?

    init(project: KanbanProject) {
        let initial = KanbanLabelCatalogDraft(from: project.labels)
        _draft = State(initialValue: initial)
        self.mode = .project(project)
    }

    init(defaults: Void) {
        let labels = KanbanBoardDefaults().labels ?? KanbanTemplate.defaultLabels
        let models = labels.map { label in
            let model = KanbanLabel(name: label.name, colorHex: label.colorHex)
            model.symbolName = label.symbolName
            return model
        }
        let initial = KanbanLabelCatalogDraft(from: models)
        _draft = State(initialValue: initial)
        self.mode = .defaults
    }

    private var title: String {
        switch mode {
        case .project(let project):
            return "Edit labels — \(project.name)"
        case .defaults:
            return "Default labels for new boards"
        }
    }

    private var cardCount: [UUID: Int] {
        guard case .project(let project) = mode else { return [:] }
        var counts: [UUID: Int] = [:]
        for task in project.tasks where task.archivedAt == nil {
            for label in task.labels {
                counts[label.id, default: 0] += 1
            }
        }
        for task in project.tasks where task.archivedAt != nil {
            for label in task.labels {
                counts[label.id, default: 0] += 1
            }
        }
        return counts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(draft.labels) { label in
                        labelRow(label)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)

            HStack(spacing: 12) {
                Button(action: { addLabel() }) {
                    Label("Add label", systemImage: "plus")
                }
                .accessibilityIdentifier("kanban-label-add")
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            Text("Changes apply when you choose Done.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("kanban-label-cancel")
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("kanban-label-done")
                    .disabled(draft.validationError != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 500)
        .confirmationDialog("Delete label?", isPresented: .constant(deleteConfirmID != nil), presenting: deleteConfirmID) { labelID in
            Button("Delete", role: .destructive) {
                draft.delete(id: labelID)
                deleteConfirmID = nil
            }
            Button("Cancel", role: .cancel) {
                deleteConfirmID = nil
            }
        } message: { labelID in
            let count = cardCount[labelID] ?? 0
            if count > 0 {
                Text("Remove it from \(count) card\(count == 1 ? "" : "s")? The cards stay on the board.")
            } else {
                Text("Delete this label?")
            }
        }
    }

    @ViewBuilder
    private func labelRow(_ label: KanbanLabelCatalogDraft.DraftLabel) -> some View {
        if editingID == label.id {
            editingForm(label)
        } else {
            displayRow(label)
        }
    }

    @ViewBuilder
    private func displayRow(_ label: KanbanLabelCatalogDraft.DraftLabel) -> some View {
        HStack(spacing: 12) {
            // Color swatch
            Circle()
                .fill(Color(hex: label.colorHex) ?? .gray)
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(Color.primary, lineWidth: 0.5))

            // Symbol and name
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let symbolName = label.symbolName {
                        Image(systemName: symbolName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(label.name)
                }

                if case .project = mode {
                    let count = cardCount[label.id] ?? 0
                    Text(count == 1 ? "1 card" : "\(count) cards")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Move buttons
            HStack(spacing: 4) {
                Button(action: { draft.moveUp(id: label.id) }) {
                    Image(systemName: "chevron.up")
                        .imageScale(.small)
                }
                .help("Move up")
                .accessibilityIdentifier("kanban-label-move-up-\(label.id.uuidString)")
                .disabled(draft.labels.first?.id == label.id)

                Button(action: { draft.moveDown(id: label.id) }) {
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
                .help("Move down")
                .accessibilityIdentifier("kanban-label-move-down-\(label.id.uuidString)")
                .disabled(draft.labels.last?.id == label.id)
            }
            .buttonStyle(.plain)

            // Edit/Delete buttons
            HStack(spacing: 4) {
                Button(action: { startEditing(label) }) {
                    Image(systemName: "pencil")
                        .imageScale(.small)
                }
                .help("Edit")
                .accessibilityIdentifier("kanban-label-edit-\(label.id.uuidString)")

                Button(action: { confirmDelete(label) }) {
                    Image(systemName: "trash")
                        .imageScale(.small)
                }
                .help("Delete")
                .accessibilityIdentifier("kanban-label-delete-\(label.id.uuidString)")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
        .accessibilityIdentifier("kanban-label-row-\(label.id.uuidString)")
    }

    @ViewBuilder
    private func editingForm(_ label: KanbanLabelCatalogDraft.DraftLabel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Label name", text: $editName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("kanban-label-name")

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Color").font(.caption).foregroundStyle(.secondary)
                            ColorPicker("", selection: $editColor)
                                .accessibilityIdentifier("kanban-label-color")
                                .frame(width: 80)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Symbol").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $editSymbolName) {
                                Text("None").tag(String?.none)
                                ForEach(symbolOptions, id: \.self) { symbol in
                                    Label(symbol, systemImage: symbol).tag(Optional(symbol))
                                }
                            }
                            .accessibilityIdentifier("kanban-label-symbol")
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                Spacer()

                VStack(spacing: 8) {
                    Button(action: { saveEdit(label) }) {
                        Image(systemName: "checkmark")
                            .imageScale(.small)
                    }
                    .help("Save")

                    Button(action: { cancelEdit() }) {
                        Image(systemName: "xmark")
                            .imageScale(.small)
                    }
                    .help("Cancel")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
    }

    private func startEditing(_ label: KanbanLabelCatalogDraft.DraftLabel) {
        editingID = label.id
        editName = label.name
        editColor = Color(hex: label.colorHex) ?? .gray
        editSymbolName = label.symbolName
    }

    private func cancelEdit() {
        editingID = nil
        editName = ""
        editColor = .gray
        editSymbolName = nil
    }

    private func saveEdit(_ label: KanbanLabelCatalogDraft.DraftLabel) {
        let trimmedName = editName.trimmingCharacters(in: .whitespaces)
        let hexValue: String
        if let components = editColor.cgColor?.components, components.count >= 3 {
            let r = Int(components[0] * 255)
            let g = Int(components[1] * 255)
            let b = Int(components[2] * 255)
            hexValue = String(format: "#%02X%02X%02X", r, g, b)
        } else {
            hexValue = "#8E8E93"
        }
        draft.edit(id: label.id, name: trimmedName, colorHex: hexValue, symbolName: editSymbolName)
        cancelEdit()
    }

    private func addLabel() {
        let newLabel = KanbanLabelCatalogDraft.DraftLabel(
            id: UUID(),
            name: "New label",
            colorHex: "#8E8E93",
            symbolName: nil
        )
        draft.add(name: newLabel.name, colorHex: newLabel.colorHex, symbolName: newLabel.symbolName)
        startEditing(newLabel)
    }

    private func confirmDelete(_ label: KanbanLabelCatalogDraft.DraftLabel) {
        deleteConfirmID = label.id
    }

    private func done() {
        error = nil

        if let validationError = draft.validationError {
            error = validationError
            return
        }

        switch mode {
        case .project(let project):
            let changes = draft.buildChanges()
            do {
                app.runKanban {
                    try app.kanbanService(context).applyLabelChanges(changes, to: project)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }

        case .defaults:
            do {
                let labels = draft.labels.map { label in
                    KanbanTemplate.Label(name: label.name, colorHex: label.colorHex, symbolName: label.symbolName)
                }
                var defaults = KanbanBoardDefaults()
                defaults.labels = labels.isEmpty ? [] : labels
                try defaults.save()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private let symbolOptions = [
        "tag", "sparkles", "ladybug.fill", "arrow.up.circle", "wrench.and.screwdriver.fill",
        "lightbulb.fill", "doc.text", "checkmark.circle", "flag.fill", "star.fill"
    ]
}

