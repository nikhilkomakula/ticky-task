import Testing
import Foundation
import SwiftData
@testable import TickyTask

@MainActor
@Suite("Rich notes")
struct RichNotesTests {
    private func makeContext() -> ModelContext {
        ModelContext(ModelContainerProvider.makeInMemoryContainer())
    }

    /// A representative document exercising supported block kinds and inline styles.
    private func sampleDocument() -> NotesDocument {
        NotesDocument(blocks: [
            NotesBlock(kind: .paragraph, runs: [
                NotesRun(text: "Plain "),
                NotesRun(text: "bold", bold: true),
                NotesRun(text: " "),
                NotesRun(text: "italic", italic: true),
                NotesRun(text: " "),
                NotesRun(text: "under", underline: true),
                NotesRun(text: " "),
                NotesRun(text: "strike", strikethrough: true),
                NotesRun(text: " "),
                NotesRun(text: "link", link: URL(string: "https://example.com"))
            ]),
            NotesBlock(kind: .bullet, runs: [NotesRun(text: "a bullet")]),
            NotesBlock(kind: .numbered, runs: [NotesRun(text: "first")])
        ])
    }

    // MARK: JSON round-trip

    @Test("NotesDocument JSON encode/decode round-trips exactly")
    func jsonRoundTrip() throws {
        let doc = sampleDocument()
        let data = try NotesCodec.encode(doc)
        #expect(try NotesCodec.decode(data) == doc)
    }

    // MARK: AttributedString round-trip (the editor's on-screen representation)

    @Test("attributedString ⇄ document preserves supported kinds and inline styles")
    func attributedRoundTrip() {
        let doc = sampleDocument()
        let attributed = NotesAttributedString.attributedString(from: doc)
        let back = NotesAttributedString.document(from: attributed)

        #expect(back.blocks.map(\.kind) == [.paragraph, .bullet, .numbered])

        // Inline styles on the first block round-trip.
        let firstRuns = back.blocks[0].runs
        #expect(firstRuns.contains { $0.text == "bold" && $0.bold })
        #expect(firstRuns.contains { $0.text == "italic" && $0.italic })
        #expect(firstRuns.contains { $0.text == "under" && $0.underline })
        #expect(firstRuns.contains { $0.text == "strike" && $0.strikethrough })
        #expect(firstRuns.contains { $0.text == "link" && $0.link == URL(string: "https://example.com") })

        // Block text is preserved without markers/glyphs.
        #expect(back.blocks[1].text == "a bullet")
    }

    // MARK: Legacy Markdown import

    @Test("Markdown import maps line prefixes to block kinds and inline emphasis")
    func markdownImport() {
        let doc = NotesCodec.document(fromMarkdown: "- [ ] todo\n- [x] done\n- bullet\n1. numbered\n**bold** rest")
        #expect(doc.blocks.map(\.kind) == [.bullet, .bullet, .bullet, .numbered, .paragraph])
        #expect(doc.blocks[0].text == "todo")
        #expect(doc.blocks[1].text == "done")
        #expect(doc.blocks[4].runs.contains { $0.text == "bold" && $0.bold })
    }

    // MARK: Plain-text projection (search)

    @Test("plainText is marker-free and searchable")
    func plainTextProjection() {
        let doc = sampleDocument()
        let text = doc.plainText
        #expect(!text.contains("☐"))
        #expect(!text.contains("☑"))
        #expect(!text.contains("•"))
        #expect(text.localizedCaseInsensitiveContains("bullet"))
        #expect(text.localizedCaseInsensitiveContains("bold"))
    }

    // MARK: Live SwiftData column round-trip

    @Test("TaskItem.notesRich Data column persists and decodes")
    func modelColumnRoundTrip() throws {
        let context = makeContext()
        let service = DataService(context)
        let doc = sampleDocument()
        let task = try service.addTask(title: "Notes task", location: .day("20260817"))
        task.notesRich = try NotesCodec.encode(doc)
        try service.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
        let data = try #require(fetched.notesRich)
        #expect(try NotesCodec.decode(data) == doc)
    }

    // MARK: Resolve rule (legacy fallback)

    @Test("resolved falls back to Markdown import when the rich payload is absent")
    func resolvedFallsBackToMarkdown() {
        let doc = NotesCodec.resolved(fromRich: nil, markdown: "- [x] shipped")
        #expect(doc.blocks.count == 1)
        #expect(doc.blocks[0].kind == .bullet)
        #expect(doc.blocks[0].text == "shipped")
    }

    @Test("resolved prefers the rich payload when present")
    func resolvedPrefersRich() throws {
        let source = sampleDocument()
        let rich = try NotesCodec.encode(source)
        let doc = NotesCodec.resolved(fromRich: rich, markdown: "ignored markdown")
        #expect(doc == source)
    }

    @Test("Legacy checkbox JSON decodes and renders back as a bullet")
    func legacyCheckboxRendersAsBullet() throws {
        let legacy = NotesDocument(blocks: [NotesBlock(kind: .checkbox, checked: true, runs: [NotesRun(text: "legacy")])])
        let decoded = try NotesCodec.decode(NotesCodec.encode(legacy))
        #expect(decoded.blocks[0].kind == .checkbox)
        let rendered = NotesAttributedString.attributedString(from: decoded)
        let reparsed = NotesAttributedString.document(from: rendered)
        #expect(reparsed.blocks[0].kind == .checkbox)
        #expect(reparsed.blocks[0].text == "legacy")
    }

    @Test("Bold and italic combine without dropping either trait")
    func inlineBoldItalicCombination() {
        let doc = NotesDocument(blocks: [NotesBlock(runs: [NotesRun(text: "both", bold: true, italic: true)])])
        let back = NotesAttributedString.document(from: NotesAttributedString.attributedString(from: doc))
        #expect(back.blocks[0].runs[0].bold && back.blocks[0].runs[0].italic)
    }

    @Test("Formatting a cross-run selection preserves the text")
    func crossRunSelectionFormatting() {
        let doc = NotesDocument(blocks: [NotesBlock(runs: [NotesRun(text: "ab"), NotesRun(text: "cd", italic: true)])])
        let result = NotesEditingEngine.toggleInlineFormat(.bold, in: doc, selection: NSRange(location: 1, length: 2))
        #expect(result.document.plainText == "abcd")
        #expect(result.document.blocks[0].runs.filter(\.bold).map(\.text).joined() == "bc")
    }

    @Test("Link scheme allowlist rejects non-web schemes")
    func linkSchemeAllowlist() {
        #expect(NotesEditingEngine.validateWebURL("file:///tmp/a") == nil)
        #expect(NotesEditingEngine.validateWebURL("javascript:alert(1)") == nil)
        #expect(NotesEditingEngine.validateWebURL("mailto:a@example.com") == nil)
    }

    @Test("Numbered lists renumber after an item is deleted")
    func numberedListRenumberAfterDelete() {
        var doc = NotesDocument(blocks: (1...3).map { NotesBlock(kind: .numbered, runs: [NotesRun(text: "item\($0)")]) })
        doc.blocks.remove(at: 1)
        #expect(String(NotesAttributedString.attributedString(from: doc).characters) == "1. item1\n2. item3")
    }

    @Test("A paragraph boundary restarts numbered ordinals")
    func paragraphBoundaryRestartsNumberedOrdinals() {
        let doc = NotesDocument(blocks: [
            NotesBlock(kind: .numbered, runs: [NotesRun(text: "one")]),
            NotesBlock(runs: [NotesRun(text: "break")]),
            NotesBlock(kind: .numbered, runs: [NotesRun(text: "again")])
        ])
        #expect(String(NotesAttributedString.attributedString(from: doc).characters) == "1. one\nbreak\n1. again")
    }

    @Test("Markdown checkbox state is retained on bullet blocks")
    func markdownCheckboxImport() {
        let doc = NotesCodec.document(fromMarkdown: "- [ ] open\n- [x] done")
        #expect(doc.blocks.map(\.kind) == [.bullet, .bullet])
        #expect(doc.blocks.map(\.checked) == [false, true])
    }

    @Test("Whitespace-only notes survive rich persistence")
    func whitespaceOnlyPersistence() throws {
        let doc = NotesDocument(blocks: [NotesBlock(runs: [NotesRun(text: "   ")])])
        #expect(try NotesCodec.decode(NotesCodec.encode(doc)) == doc)
    }

    @Test("Resolving notes for display does not mutate updatedAt")
    func noEditGuard() {
        let task = TaskItem(title: "No edit", dayKey: "20260818")
        let original = Date(timeIntervalSince1970: 1234)
        task.updatedAt = original
        _ = NotesAttributedString.attributedString(from: NotesCodec.resolved(fromRich: task.notesRich, markdown: task.notes))
        #expect(task.updatedAt == original)
    }
}
