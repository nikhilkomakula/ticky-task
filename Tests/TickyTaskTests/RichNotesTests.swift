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
        #expect(reparsed.blocks[0].kind == .bullet)
        #expect(reparsed.blocks[0].text == "legacy")
    }
}
