import Foundation
import Testing
@testable import TickyTask

@Suite("Notes editing engine")
struct NotesEditingEngineTests {
    private func doc(_ runs: [NotesRun], kind: NotesBlock.Kind = .paragraph, indent: Int = 0) -> NotesDocument {
        NotesDocument(blocks: [NotesBlock(kind: kind, indent: indent, runs: runs)])
    }
    private func contentRange(_ document: NotesDocument, block: Int = 0) -> NSRange {
        NotesEditingEngine.contentStartRange(ofBlock: block, in: document,
                                             rendered: NotesEditingEngine.render(document)) ?? NSRange()
    }

    @Test func testToggleBoldOnSelection() { let d = doc([NotesRun(text: "abc")]); let ok = NotesEditingEngine.toggleInlineFormat(.bold, in: d, selection: contentRange(d)).document.blocks[0].runs.allSatisfy(\.bold); #expect(ok) }
    @Test func testToggleBoldUniformOn_partialSelection() { let d = doc([NotesRun(text: "a", bold: true), NotesRun(text: "bc")]); let ok = NotesEditingEngine.toggleInlineFormat(.bold, in: d, selection: contentRange(d)).document.blocks[0].runs.allSatisfy(\.bold); #expect(ok) }
    @Test func testToggleBoldUniformOff_allBold() { let d = doc([NotesRun(text: "abc", bold: true)]); let ok = NotesEditingEngine.toggleInlineFormat(.bold, in: d, selection: contentRange(d)).document.blocks[0].runs.allSatisfy { !$0.bold }; #expect(ok) }
    @Test func testTogglePreservesUnrelatedFormats() { let d = doc([NotesRun(text: "abc", bold: true, italic: true)]); let r = NotesEditingEngine.toggleInlineFormat(.bold, in: d, selection: contentRange(d)).document.blocks[0].runs[0]; #expect(!r.bold && r.italic) }
    @Test func testRemoveInlineFormatting() { let d = doc([NotesRun(text: "abc", bold: true, italic: true, underline: true, strikethrough: true, link: URL(string: "https://example.com"))]); let r = NotesEditingEngine.removeInlineFormatting(in: d, selection: contentRange(d)).document.blocks[0].runs[0]; #expect(!r.hasStyle) }
    @Test func testValidateWebURL_valid_http() { #expect(NotesEditingEngine.validateWebURL("http://example.com") != nil) }
    @Test func testValidateWebURL_valid_https() { #expect(NotesEditingEngine.validateWebURL("https://example.com/path") != nil) }
    @Test func testValidateWebURL_missingHost_rejected() { #expect(NotesEditingEngine.validateWebURL("https:payload") == nil) }
    @Test func testValidateWebURL_badScheme_rejected() { #expect(NotesEditingEngine.validateWebURL("file:///tmp") == nil); #expect(NotesEditingEngine.validateWebURL("javascript:alert(1)") == nil) }
    @Test func testApplyLink_validSelection() { let d = doc([NotesRun(text: "abc")]); #expect(NotesEditingEngine.applyLink("https://example.com", in: d, selection: contentRange(d))?.document.blocks[0].runs[0].link != nil) }
    @Test func testApplyLink_emptySelection_returnsNil() { #expect(NotesEditingEngine.applyLink("https://example.com", in: doc([NotesRun(text: "a")]), selection: NSRange(location: 0, length: 0)) == nil) }

    @Test func testToggleList_enableOnParagraph() { let d = doc([NotesRun(text: "abc", italic: true)]); let r = NotesEditingEngine.toggleList(kind: .bullet, in: d, selection: contentRange(d)).document.blocks[0]; #expect(r.kind == .bullet && r.runs[0].italic) }
    @Test func testToggleList_scopedToSelection_notWholeNote() { let d = NotesDocument(blocks: [NotesBlock(runs: [NotesRun(text: "one")]), NotesBlock(runs: [NotesRun(text: "two")])]); let r = NotesEditingEngine.toggleList(kind: .bullet, in: d, selection: contentRange(d, block: 0)).document; #expect(r.blocks.map(\.kind) == [.bullet, .paragraph]) }
    @Test func testToggleList_toggleOffWhenAllSelected() { let d = NotesDocument(blocks: [NotesBlock(kind: .bullet, runs: [NotesRun(text: "a")]), NotesBlock(kind: .bullet, runs: [NotesRun(text: "b")])]); let all = NSRange(location: 0, length: String(NotesEditingEngine.render(d).characters).utf16.count); let ok = NotesEditingEngine.toggleList(kind: .bullet, in: d, selection: all).document.blocks.allSatisfy { $0.kind == .paragraph }; #expect(ok) }
    @Test func testToggleList_caretStaysInSelection() { let d = doc([NotesRun(text: "abc")]); let r = NotesEditingEngine.toggleList(kind: .bullet, in: d, selection: NSRange(location: 1, length: 0)); #expect(r.selection.location < String(NotesEditingEngine.render(r.document).characters).utf16.count) }
    @Test func testToggleList_switchBulletToNumbered() { let d = doc([NotesRun(text: "a")], kind: .bullet); #expect(NotesEditingEngine.toggleList(kind: .numbered, in: d, selection: contentRange(d)).document.blocks[0].kind == .numbered) }
    @Test func testToggleList_mixedContent() { let d = NotesDocument(blocks: [NotesBlock(runs: [NotesRun(text: "a")]), NotesBlock(kind: .bullet, runs: [NotesRun(text: "b")])]); let all = NSRange(location: 0, length: String(NotesEditingEngine.render(d).characters).utf16.count); let ok = NotesEditingEngine.toggleList(kind: .bullet, in: d, selection: all).document.blocks.allSatisfy { $0.kind == .bullet }; #expect(ok) }

    @Test func testContinueList_emptyItem_becomesParagraph() { let d = doc([], kind: .bullet); #expect(NotesEditingEngine.continueList(in: d, caretOffsetInRendered: 2, rendered: NotesEditingEngine.render(d))?.document.blocks[0].kind == .paragraph) }
    @Test func testContinueList_endOfItem_appendsNewItem() { let d = doc([NotesRun(text: "first")], kind: .bullet); let caret = NSMaxRange(contentRange(d)); #expect(NotesEditingEngine.continueList(in: d, caretOffsetInRendered: caret, rendered: NotesEditingEngine.render(d))?.document.blocks.count == 2) }
    @Test func testContinueList_midItem_splitsRuns() { let d = doc([NotesRun(text: "firstsecond", bold: true)], kind: .bullet); let r = NotesEditingEngine.continueList(in: d, caretOffsetInRendered: contentRange(d).location + 5, rendered: NotesEditingEngine.render(d))?.document; #expect(r?.blocks.map(\.text) == ["first", "second"]) }
    @Test func testContinueList_inheritsKindAndIndent() { let d = doc([NotesRun(text: "a")], kind: .numbered, indent: 2); let r = NotesEditingEngine.continueList(in: d, caretOffsetInRendered: NSMaxRange(contentRange(d)), rendered: NotesEditingEngine.render(d)); #expect(r?.document.blocks[1].kind == .numbered && r?.document.blocks[1].indent == 2) }
    @Test func testContinueList_onParagraph_returnsNil() { let d = doc([NotesRun(text: "a")]); #expect(NotesEditingEngine.continueList(in: d, caretOffsetInRendered: 1, rendered: NotesEditingEngine.render(d)) == nil) }
    @Test func testContinueList_emptyDocument_returnsNil() { let d = NotesDocument(); #expect(NotesEditingEngine.continueList(in: d, caretOffsetInRendered: 0, rendered: NotesEditingEngine.render(d)) == nil) }
    @Test func testIndentBlocks_listItem() { let d = doc([NotesRun(text: "a")], kind: .bullet); #expect(NotesEditingEngine.indentBlocks(in: d, selection: contentRange(d)).document.blocks[0].indent == 1) }
    @Test func testIndentBlocks_paragraph_promotesToBulletAtLevel0() { let d = doc([NotesRun(text: "a")]); let b = NotesEditingEngine.indentBlocks(in: d, selection: contentRange(d)).document.blocks[0]; #expect(b.kind == .bullet && b.indent == 0) }
    @Test func testIndentBlocks_capAt5() { let d = doc([NotesRun(text: "a")], kind: .bullet, indent: 5); #expect(NotesEditingEngine.indentBlocks(in: d, selection: contentRange(d)).document.blocks[0].indent == 5) }
    @Test func testOutdentBlocks_listItem() { let d = doc([NotesRun(text: "a")], kind: .bullet, indent: 2); #expect(NotesEditingEngine.outdentBlocks(in: d, selection: contentRange(d)).document.blocks[0].indent == 1) }
    @Test func testOutdentBlocks_atZero_becomesParagraph() { let d = doc([NotesRun(text: "a")], kind: .bullet); #expect(NotesEditingEngine.outdentBlocks(in: d, selection: contentRange(d)).document.blocks[0].kind == .paragraph) }
    @Test func testContinueList_inheritsIndent() { let d = doc([NotesRun(text: "a")], kind: .bullet, indent: 2); #expect(NotesEditingEngine.continueList(in: d, caretOffsetInRendered: NSMaxRange(contentRange(d)), rendered: NotesEditingEngine.render(d))?.document.blocks[1].indent == 2) }
    @Test func testToggleList_emptyNote_createsItem() { let r = NotesEditingEngine.toggleList(kind: .bullet, in: NotesDocument(), selection: NSRange(location: 0, length: 0)); #expect(r.document.blocks.count == 1 && r.document.blocks[0].kind == .bullet) }
    @Test func testContinueList_emptyNestedItem_outdents() { let d = doc([], kind: .bullet, indent: 2); let r = NotesEditingEngine.continueList(in: d, caretOffsetInRendered: NSMaxRange(contentRange(d)), rendered: NotesEditingEngine.render(d)); #expect(r?.document.blocks[0].kind == .bullet && r?.document.blocks[0].indent == 1) }
    @Test func testNumberedOrdinals_reNestRestart() { let d = NotesDocument(blocks: [NotesBlock(kind: .numbered, runs: [NotesRun(text: "a")]), NotesBlock(kind: .numbered, indent: 1, runs: [NotesRun(text: "b")]), NotesBlock(kind: .numbered, indent: 1, runs: [NotesRun(text: "c")]), NotesBlock(kind: .numbered, runs: [NotesRun(text: "d")]), NotesBlock(kind: .numbered, indent: 1, runs: [NotesRun(text: "e")])]); #expect(String(NotesEditingEngine.render(d).characters) == "1. a\n  1. b\n  2. c\n2. d\n  1. e") }

    @Test func testNumberedOrdinals_restartAfterIndentChange() { let d = NotesDocument(blocks: [NotesBlock(kind: .numbered, runs: [NotesRun(text: "a")]), NotesBlock(kind: .numbered, indent: 1, runs: [NotesRun(text: "b")]), NotesBlock(kind: .numbered, runs: [NotesRun(text: "c")])]); #expect(String(NotesEditingEngine.render(d).characters) == "1. a\n  1. b\n2. c") }
    @Test func testRenderParse_roundTrip() { let d = NotesDocument(blocks: [NotesBlock(kind: .paragraph, runs: [NotesRun(text: "all", bold: true, italic: true)]), NotesBlock(kind: .bullet, indent: 1, runs: [NotesRun(text: "u", underline: true)]), NotesBlock(kind: .checkbox, checked: true, runs: [NotesRun(text: "s", strikethrough: true)])]); #expect(NotesEditingEngine.parseEditorRepresentation(NotesEditingEngine.render(d)) == d) }
    @Test func testRenderParse_emptyDocument_zeroBlocks() { #expect(NotesEditingEngine.parseEditorRepresentation(NotesEditingEngine.render(NotesDocument())).blocks.isEmpty) }
    @Test func testRenderParse_IDsPreserved() { let ids = [UUID(), UUID()]; let d = NotesDocument(blocks: [NotesBlock(id: ids[0], runs: [NotesRun(text: "a")]), NotesBlock(id: ids[1], kind: .bullet, runs: [NotesRun(text: "b")])]); #expect(NotesEditingEngine.parseEditorRepresentation(NotesEditingEngine.render(d)).blocks.map(\.id) == ids) }
    @Test func testRenderParse_unicode() { let d = doc([NotesRun(text: "café 👩🏽‍💻")]); #expect(NotesEditingEngine.parseEditorRepresentation(NotesEditingEngine.render(d)).plainText == d.plainText) }
    @Test func testRenderParse_multiDigitMarker() { let d = NotesDocument(blocks: (0..<10).map { NotesBlock(kind: .numbered, runs: [NotesRun(text: "\($0)")]) }); #expect(NotesEditingEngine.parseEditorRepresentation(NotesEditingEngine.render(d)).blocks.count == 10) }
    @Test func testRenderParse_proseStartingWithBullet_notMisidentified() { let d = doc([NotesRun(text: "• prose")]); #expect(NotesEditingEngine.parseEditorRepresentation(NotesEditingEngine.render(d)).blocks[0].kind == .paragraph) }
    @Test func testRenderParse_proseStartingWithNumber_notMisidentified() { let d = doc([NotesRun(text: "1. prose")]); #expect(NotesEditingEngine.parseEditorRepresentation(NotesEditingEngine.render(d)).blocks[0].kind == .paragraph) }

    @Test func testCodecIdentity() throws { let d = doc([NotesRun(text: "a")]); let decoded = try NotesCodec.decode(NotesCodec.encode(d)); #expect(decoded == d) }
    @Test func testCodecResolve_nilRich_usesMarkdown() { #expect(NotesCodec.resolved(fromRich: nil, markdown: "**bold**").blocks[0].runs[0].bold) }
    @Test func testCodecResolve_emptyBlocksRich_doesNotFallback() throws { let rich = try NotesCodec.encode(NotesDocument()); #expect(NotesCodec.resolved(fromRich: rich, markdown: "fallback").blocks.isEmpty) }
    @Test func testCodecResolve_corruptRich_usesMarkdown() { #expect(NotesCodec.resolved(fromRich: Data("garbage".utf8), markdown: "fallback").plainText == "fallback") }
    @Test func testMarkdownImport_bold() { #expect(NotesCodec.document(fromMarkdown: "**bold**").blocks[0].runs[0].bold) }
    @Test func testMarkdownImport_italic() { #expect(NotesCodec.document(fromMarkdown: "*italic*").blocks[0].runs[0].italic) }
    @Test func testMarkdownImport_strike() { #expect(NotesCodec.document(fromMarkdown: "~~strike~~").blocks[0].runs[0].strikethrough) }
    @Test func testMarkdownImport_bulletDash() { #expect(NotesCodec.document(fromMarkdown: "- item").blocks[0].kind == .bullet) }
    @Test func testMarkdownImport_numbered() { #expect(NotesCodec.document(fromMarkdown: "1. item").blocks[0].kind == .numbered) }
    @Test func testPlainTextProjection_listItemsIncluded() { #expect(doc([NotesRun(text: "item")], kind: .bullet).plainText == "item") }
    @Test func testPlainTextProjection_emptyDocument() { #expect(NotesDocument().plainText == "") }
}
