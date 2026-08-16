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

    /// A representative document exercising every block kind and inline style.
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
            NotesBlock(kind: .numbered, runs: [NotesRun(text: "first")]),
            NotesBlock(kind: .checkbox, checked: false, runs: [NotesRun(text: "todo")]),
            NotesBlock(kind: .checkbox, checked: true, runs: [NotesRun(text: "done")])
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

    @Test("attributedString ⇄ document preserves kinds, checked state, and inline styles")
    func attributedRoundTrip() {
        let doc = sampleDocument()
        let attributed = NotesAttributedString.attributedString(from: doc)
        let back = NotesAttributedString.document(from: attributed)

        #expect(back.blocks.map(\.kind) == [.paragraph, .bullet, .numbered, .checkbox, .checkbox])
        #expect(back.blocks.map(\.checked) == [false, false, false, false, true])

        // The checkbox block ids survive (carried in the toggle link) so toggles
        // target the right item after a round-trip.
        #expect(back.blocks[3].id == doc.blocks[3].id)
        #expect(back.blocks[4].id == doc.blocks[4].id)

        // Inline styles on the first block round-trip.
        let firstRuns = back.blocks[0].runs
        #expect(firstRuns.contains { $0.text == "bold" && $0.bold })
        #expect(firstRuns.contains { $0.text == "italic" && $0.italic })
        #expect(firstRuns.contains { $0.text == "under" && $0.underline })
        #expect(firstRuns.contains { $0.text == "strike" && $0.strikethrough })
        #expect(firstRuns.contains { $0.text == "link" && $0.link == URL(string: "https://example.com") })

        // Block text is preserved without markers/glyphs.
        #expect(back.blocks[1].text == "a bullet")
        #expect(back.blocks[3].text == "todo")
    }

    // MARK: Legacy Markdown import

    @Test("Markdown import maps line prefixes to block kinds and inline emphasis")
    func markdownImport() {
        let doc = NotesCodec.document(fromMarkdown: "- [ ] todo\n- [x] done\n- bullet\n1. numbered\n**bold** rest")
        #expect(doc.blocks.map(\.kind) == [.checkbox, .checkbox, .bullet, .numbered, .paragraph])
        #expect(doc.blocks.map(\.checked) == [false, true, false, false, false])
        #expect(doc.blocks[4].runs.contains { $0.text == "bold" && $0.bold })
    }

    // MARK: Plain-text projection (search)

    @Test("plainText is marker-free and searchable inside checklist items")
    func plainTextProjection() {
        let doc = sampleDocument()
        let text = doc.plainText
        #expect(!text.contains("☐"))
        #expect(!text.contains("☑"))
        #expect(!text.contains("•"))
        // A word inside a checkbox block is findable, so SearchService keeps working.
        #expect(text.localizedCaseInsensitiveContains("done"))
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
        #expect(doc.blocks[0].kind == .checkbox)
        #expect(doc.blocks[0].checked)
        #expect(doc.blocks[0].text == "shipped")
    }

    @Test("resolved prefers the rich payload when present")
    func resolvedPrefersRich() throws {
        let source = sampleDocument()
        let rich = try NotesCodec.encode(source)
        let doc = NotesCodec.resolved(fromRich: rich, markdown: "ignored markdown")
        #expect(doc == source)
    }
}
