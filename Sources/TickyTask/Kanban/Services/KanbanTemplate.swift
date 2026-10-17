import Foundation

/// A board's structure: its columns and labels, without cards or people. New boards start
/// from one; any board can be saved as one, or duplicated through one.
struct KanbanTemplate: Codable, Equatable, Identifiable, Sendable {
    struct Column: Codable, Equatable, Sendable {
        var name: String
        var kind: KanbanColumnKind
        var colorHex: String?
        var wipLimit: Int?
        var symbolName: String? = nil
    }

    struct Label: Codable, Equatable, Sendable {
        var name: String
        var colorHex: String
        var symbolName: String?
    }

    var id: UUID
    var name: String
    var columns: [Column]
    var labels: [Label]
    var isBuiltIn = false

    static let defaultLabels: [Label] = [
        ("Feature", "#34C759"), ("Bug", "#FF3B30"), ("Enhancement", "#007AFF"), ("Tech Debt", "#AF52DE"),
        ("Spike", "#FF9500"), ("Documentation", "#5AC8FA"), ("Chore", "#8E8E93"),
    ].map { Label(name: $0.0, colorHex: $0.1) }

    /// To Do → In Progress → Done.
    static let standard = KanbanTemplate(
        id: UUID(uuidString: "6B5E2A10-0000-4000-8000-000000000001")!, name: "Default",
        columns: [.init(name: "To Do", kind: .backlog), .init(name: "In Progress", kind: .active), .init(name: "Done", kind: .done)],
        labels: defaultLabels, isBuiltIn: true)

    /// Backlog → To Do → In Progress → In Review → Done.
    static let software = KanbanTemplate(
        id: UUID(uuidString: "6B5E2A10-0000-4000-8000-000000000002")!, name: "Software",
        columns: [.init(name: "Backlog", kind: .backlog), .init(name: "To Do", kind: .active), .init(name: "In Progress", kind: .active),
                  .init(name: "In Review", kind: .active), .init(name: "Done", kind: .done)],
        labels: defaultLabels, isBuiltIn: true)

    /// Why this template can't make a valid board, or nil.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "A template needs a name." }
        if columns.filter({ $0.kind == .backlog }).count != 1 { return "A template needs exactly one backlog column." }
        if !columns.contains(where: { $0.kind == .done }) { return "A template needs a Done column." }
        if columns.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) { return "Every column needs a name." }
        return nil
    }

    /// The structure of `project`, as a new user template.
    @MainActor
    init(from project: KanbanProject, name: String) {
        self.id = UUID()
        self.name = name
        self.columns = project.orderedColumns.map { Column(name: $0.name, kind: $0.kind, colorHex: $0.colorHex, wipLimit: $0.wipLimit, symbolName: $0.symbolName) }
        self.labels = project.labels.sorted { $0.sortIndex < $1.sortIndex }
            .map { Label(name: $0.name, colorHex: $0.colorHex, symbolName: $0.symbolName) }
    }

    init(id: UUID, name: String, columns: [Column], labels: [Label], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.columns = columns
        self.labels = labels
        self.isBuiltIn = isBuiltIn
    }
}

/// User templates, stored as JSON under `kanban.templates` so they travel with the backed-up
/// settings. The built-in templates are never stored.
enum KanbanTemplateStore {
    static let key = "kanban.templates"

    static func all(_ defaults: UserDefaults = .standard) -> [KanbanTemplate] {
        [.standard, .software] + saved(defaults)
    }

    static func saved(_ defaults: UserDefaults = .standard) -> [KanbanTemplate] {
        guard let json = defaults.string(forKey: key), let data = json.data(using: .utf8),
              let templates = try? JSONDecoder().decode([KanbanTemplate].self, from: data) else { return [] }
        return templates.filter { !$0.isBuiltIn && $0.problem == nil }
    }

    /// Adds or replaces `template` (by id). Built-ins and invalid templates are refused.
    static func save(_ template: KanbanTemplate, _ defaults: UserDefaults = .standard) throws {
        guard !template.isBuiltIn else { throw KanbanServiceError.invariant("Built-in templates can't be changed.") }
        if let problem = template.problem { throw KanbanServiceError.invariant(problem) }
        var templates = saved(defaults).filter { $0.id != template.id }
        templates.append(template)
        try write(templates, defaults)
    }

    static func delete(_ id: UUID, _ defaults: UserDefaults = .standard) throws {
        try write(saved(defaults).filter { $0.id != id }, defaults)
    }

    private static func write(_ templates: [KanbanTemplate], _ defaults: UserDefaults) throws {
        let data = try JSONEncoder().encode(templates)
        defaults.set(String(decoding: data, as: UTF8.self), forKey: key)
    }
}
