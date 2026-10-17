import Testing
import SwiftUI
import SwiftData
@testable import TickyTask

/// Renders sample cards to PNGs for a design review, only when `CARD_SNAPSHOT_DIR` is set
/// (pass `TEST_RUNNER_CARD_SNAPSHOT_DIR=<dir>` to xcodebuild); otherwise it does nothing.
@MainActor
@Suite("Kanban card snapshots", .serialized)
struct KanbanCardSnapshotTests {
    @Test("Sample cards render in light and dark, at narrow, default and wide columns")
    func render() throws {
        guard let dir = ProcessInfo.processInfo.environment["CARD_SNAPSHOT_DIR"] else { return }
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context)
        let project = try s.createProject(name: "Platform", key: "PLAT")
        let labels = project.labels.sorted { $0.sortIndex < $1.sortIndex }
        let short = try s.createTask(in: project, title: "Triage inbox")
        let full = try s.createTask(in: project, title: "Build the public API gateway with rate limiting and audit logging",
                                    dueDate: Calendar.current.date(byAdding: .day, value: -2, to: Date()))
        try s.edit(full, [.priority: .int(TaskPriority.high.rawValue), .isCritical: .bool(true), .isBlocked: .bool(true),
                          .blockedReason: .string("Waiting on keys"), .jiraURL: .string("https://jira.example.com/browse/PLAT-1234"),
                          .notes: .string("See the design doc")])
        try s.setLabels(full, Array(labels.prefix(4)))
        _ = try s.addSubtask(to: full, title: "Endpoints")
        let medium = try s.createTask(in: project, title: "Write docs", dueDate: Date())
        try s.edit(medium, [.priority: .int(TaskPriority.medium.rawValue)])
        try s.setLabels(medium, [labels[1]])
        let app = AppState()
        for scheme in [ColorScheme.light, .dark] {
            for width in [180.0, 250.0, 480.0] {
                let cards = VStack(alignment: .leading, spacing: 6) {
                    ForEach([short, medium, full]) { KanbanCardView(task: $0, project: project) }
                }
                .padding(6)
                .frame(width: width - 0)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(app)
                .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: cards)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("card-\(scheme == .dark ? "dark" : "light")-\(Int(width)).png"))
            }
        }
    }

    @Test("Column headers (automatic and chosen) and the Appearance popover render in light and dark")
    func renderColumns() throws {
        guard let dir = ProcessInfo.processInfo.environment["CARD_SNAPSHOT_DIR"] else { return }
        let context = ModelContext(ModelContainerProvider.makeInMemoryContainer())
        let s = KanbanService(context)
        let project = try s.createProject(name: "Platform", key: "PLAT")
        let blocked = try s.addColumn(to: project, name: "Blocked", at: 2)
        let custom = try s.addColumn(to: project, name: "Design", at: 3)
        try s.editColumn(custom, colorHex: .some(TaskColor.violet.hex), symbolName: .some("sparkles"))
        _ = blocked
        let app = AppState()
        for scheme in [ColorScheme.light, .dark] {
            let headers = VStack(spacing: 8) {
                ForEach(project.orderedColumns) { column in
                    KanbanColumnHeader(column: column, count: 3, hours: nil, trailingInset: 28).frame(width: 250, height: 40)
                }
                KanbanColumnAppearancePopover(column: project.orderedColumns[1], count: 3)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(app)
            .modelContext(context)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: headers)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("columns-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
