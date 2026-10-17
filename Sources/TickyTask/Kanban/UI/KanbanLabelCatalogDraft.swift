import Foundation

/// Pure value type for staging label edits: add, rename, recolor, reorder and delete.
/// Turns UI edits into a KanbanLabelChanges for service application.
struct KanbanLabelCatalogDraft: Equatable, Sendable {
    struct DraftLabel: Equatable, Sendable, Identifiable {
        let id: UUID
        var name: String
        var colorHex: String
        var symbolName: String?

        init(id: UUID, name: String, colorHex: String, symbolName: String? = nil) {
            self.id = id
            self.name = name
            self.colorHex = colorHex
            self.symbolName = symbolName
        }

        init(from label: KanbanLabel) {
            self.id = label.id
            self.name = label.name
            self.colorHex = label.colorHex
            self.symbolName = label.symbolName
        }
    }

    private var initialLabels: [DraftLabel]
    var labels: [DraftLabel]

    init(from labels: [KanbanLabel]) {
        let drafts = labels.sorted { $0.sortIndex < $1.sortIndex }
            .map { DraftLabel(from: $0) }
        self.initialLabels = drafts
        self.labels = drafts
    }

    /// Add a new label and return its ID.
    @discardableResult
    mutating func add(name: String, colorHex: String, symbolName: String? = nil) -> UUID {
        let id = UUID()
        labels.append(DraftLabel(id: id, name: name, colorHex: colorHex, symbolName: symbolName))
        return id
    }

    /// Edit an existing label's properties.
    mutating func edit(id: UUID, name: String?, colorHex: String?, symbolName: String?) {
        if let index = labels.firstIndex(where: { $0.id == id }) {
            if let name { labels[index].name = name }
            if let colorHex { labels[index].colorHex = colorHex }
            if let symbolName { labels[index].symbolName = symbolName }
        }
    }

    /// Sets a label's symbol exactly; nil means None.
    mutating func setSymbol(id: UUID, to symbolName: String?) {
        if let index = labels.firstIndex(where: { $0.id == id }) { labels[index].symbolName = symbolName }
    }

    /// Mark a label's symbol as cleared (the same as choosing None).
    mutating func clearSymbol(id: UUID) { setSymbol(id: id, to: nil) }

    /// Delete a label.
    mutating func delete(id: UUID) {
        labels.removeAll { $0.id == id }
    }

    /// Move a label up in the list.
    mutating func moveUp(id: UUID) {
        guard let index = labels.firstIndex(where: { $0.id == id }), index > 0 else { return }
        labels.swapAt(index, index - 1)
    }

    /// Move a label down in the list.
    mutating func moveDown(id: UUID) {
        guard let index = labels.firstIndex(where: { $0.id == id }), index < labels.count - 1 else { return }
        labels.swapAt(index, index + 1)
    }

    /// Reorder labels via drag-and-drop.
    mutating func reorder(from: IndexSet, to: Int) {
        labels.move(fromOffsets: from, toOffset: to)
    }

    /// Validate: names are non-empty and unique (case-insensitive).
    var validationError: String? {
        var seen = Set<String>()
        for label in labels {
            let trimmed = label.name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return "A label name can't be blank." }
            let lower = trimmed.lowercased()
            if seen.contains(lower) { return "Label names must be unique." }
            seen.insert(lower)
        }
        return nil
    }

    /// Build the service changes: adds (new labels not in initial), edits (modified existing),
    /// deletes (removed from initial), and the new order.
    func buildChanges() -> KanbanLabelChanges {
        var changes = KanbanLabelChanges()

        // Identify adds: labels with IDs not in initialLabels (new UUIDs)
        let initialIDs = Set(initialLabels.map { $0.id })
        for label in labels where !initialIDs.contains(label.id) {
            let trimmed = label.name.trimmingCharacters(in: .whitespaces)
            changes.adds.append(KanbanLabelChanges.Add(id: label.id, name: trimmed, colorHex: label.colorHex, symbolName: label.symbolName))
        }

        // Identify edits: labels in both, but changed
        for label in labels where initialIDs.contains(label.id) {
            if let initial = initialLabels.first(where: { $0.id == label.id }) {
                var edit: KanbanLabelChanges.Edit? = nil
                var changed = false
                let trimmedName = label.name.trimmingCharacters(in: .whitespaces)
                if trimmedName != initial.name {
                    if edit == nil { edit = KanbanLabelChanges.Edit(id: label.id) }
                    edit?.name = trimmedName
                    changed = true
                }
                if label.colorHex != initial.colorHex {
                    if edit == nil { edit = KanbanLabelChanges.Edit(id: label.id) }
                    edit?.colorHex = label.colorHex
                    changed = true
                }
                if label.symbolName != initial.symbolName {
                    if edit == nil { edit = KanbanLabelChanges.Edit(id: label.id) }
                    if let symbol = label.symbolName { edit?.symbolName = symbol } else { edit?.clearsSymbol = true }
                    changed = true
                }
                if changed, let edit { changes.edits.append(edit) }
            }
        }

        // Identify deletes: in initial but not in current
        let currentIDs = Set(labels.map { $0.id })
        for initial in initialLabels where !currentIDs.contains(initial.id) {
            changes.deleteIDs.append(initial.id)
        }

        // Order: all labels currently in the list, in order (including new ones)
        changes.orderIDs = labels.map { $0.id }

        return changes
    }
}
