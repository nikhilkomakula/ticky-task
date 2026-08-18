import Foundation

public struct NotesEditingResult: Equatable {
    public var document: NotesDocument
    public var selection: NSRange

    public init(document: NotesDocument, selection: NSRange) {
        self.document = document
        self.selection = selection
    }
}

public enum NotesInlineFormat: Hashable {
    case bold, italic, underline, strikethrough
}

public struct NotesEditingEngine {
    public init() {}

    public static func activeInlineFormats(in document: NotesDocument, selection: NSRange) -> Set<NotesInlineFormat> {
        guard selection.length > 0 else { return [] }
        let pieces = selectedRunPieces(in: document, selection: selection)
        guard !pieces.isEmpty else { return [] }
        return Set(NotesInlineFormat.allCases.filter { format in
            pieces.allSatisfy { flag(format, on: $0.run) }
        })
    }

    public static func toggleInlineFormat(_ format: NotesInlineFormat, in document: NotesDocument,
                                   selection: NSRange) -> NotesEditingResult {
        guard selection.length > 0 else { return NotesEditingResult(document: document, selection: selection) }
        let turnOn = !activeInlineFormats(in: document, selection: selection).contains(format)
        return mutateRuns(in: document, selection: selection) { run in set(format, to: turnOn, on: &run) }
    }

    public static func removeInlineFormatting(in document: NotesDocument, selection: NSRange) -> NotesEditingResult {
        guard selection.length > 0 else { return NotesEditingResult(document: document, selection: selection) }
        return mutateRuns(in: document, selection: selection) { run in
            run.bold = false; run.italic = false; run.underline = false
            run.strikethrough = false; run.link = nil
        }
    }

    public static func validateWebURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    public static func applyLink(_ urlString: String, in document: NotesDocument,
                          selection: NSRange) -> NotesEditingResult? {
        guard selection.length > 0, let url = validateWebURL(urlString) else { return nil }
        return mutateRuns(in: document, selection: selection) { $0.link = url }
    }

    public static func toggleList(kind: NotesBlock.Kind, in document: NotesDocument,
                           selection: NSRange) -> NotesEditingResult {
        // Empty note (no blocks, or only empty blocks): start a single list item and
        // place the caret after its marker, so a list can be begun on a blank note.
        if document.blocks.allSatisfy({ $0.runs.allSatisfy { $0.text.isEmpty } }) {
            var doc = document
            doc.blocks = [NotesBlock(kind: kind)]
            let caret = contentStartRange(ofBlock: 0, in: doc, rendered: render(doc))?.location
                ?? String(render(doc).characters).utf16.count
            return NotesEditingResult(document: doc, selection: NSRange(location: caret, length: 0))
        }
        let rendered = render(document)
        let indices = selectedBlockIndices(selection, rendered: rendered)
        guard !indices.isEmpty else { return NotesEditingResult(document: document, selection: selection) }
        let allAlready = indices.allSatisfy { document.blocks[$0].kind == kind }
        var result = document
        for index in indices {
            result.blocks[index].kind = allAlready ? .paragraph : kind
            result.blocks[index].checked = false
        }
        return NotesEditingResult(document: result,
                                  selection: adjustedSelection(selection, old: document, new: result))
    }

    public static func indentBlocks(in document: NotesDocument, selection: NSRange) -> NotesEditingResult {
        mutateBlocks(in: document, selection: selection) { block in
            // First indent of a paragraph makes it a top-level (indent 0) bullet;
            // further Tabs nest it deeper.
            if block.kind == .paragraph { block.kind = .bullet; block.indent = 0 }
            else { block.indent = min(5, block.indent + 1) }
        }
    }

    public static func outdentBlocks(in document: NotesDocument, selection: NSRange) -> NotesEditingResult {
        mutateBlocks(in: document, selection: selection) { block in
            guard block.kind != .paragraph else { return }
            if block.indent == 0 { block.kind = .paragraph }
            else { block.indent -= 1 }
        }
    }

    public static func continueList(in document: NotesDocument, caretOffsetInRendered: Int,
                             rendered: AttributedString) -> NotesEditingResult? {
        guard !document.blocks.isEmpty,
              let index = blockIndex(atUTF16Offset: caretOffsetInRendered, in: rendered),
              document.blocks.indices.contains(index) else { return nil }
        let block = document.blocks[index]
        guard block.kind == .bullet || block.kind == .numbered || block.kind == .checkbox else { return nil }
        var result = document
        if block.text.isEmpty {
            // Return on an empty item: a nested item outdents one level; a top-level
            // item ends the list (becomes a paragraph).
            if result.blocks[index].indent > 0 {
                result.blocks[index].indent -= 1
            } else {
                result.blocks[index].kind = .paragraph
            }
            let range = contentStartRange(ofBlock: index, in: result, rendered: render(result)) ?? NSRange(location: 0, length: 0)
            return NotesEditingResult(document: result, selection: NSRange(location: range.location, length: 0))
        }
        guard let contentRange = contentStartRange(ofBlock: index, in: document, rendered: rendered) else { return nil }
        let localOffset = min(max(0, caretOffsetInRendered - contentRange.location), block.text.utf16.count)
        let split = splitRuns(block.runs, at: localOffset)
        result.blocks[index].runs = split.before
        let newBlock = NotesBlock(kind: block.kind, checked: false, indent: block.indent, runs: split.after)
        result.blocks.insert(newBlock, at: index + 1)
        let newRendered = render(result)
        guard let newRange = contentStartRange(ofBlock: index + 1, in: result, rendered: newRendered) else { return nil }
        return NotesEditingResult(document: result, selection: NSRange(location: newRange.location, length: 0))
    }

    public static func blockIndex(atUTF16Offset offset: Int, in rendered: AttributedString) -> Int? {
        let text = String(rendered.characters) as NSString
        guard offset >= 0, offset <= text.length, text.length > 0 else { return nil }
        var start = 0
        for (index, line) in lineRanges(text).enumerated() {
            let upper = NSMaxRange(line)
            if offset >= start && (offset < upper || (offset == text.length && index == lineRanges(text).count - 1)) { return index }
            start = upper
        }
        return nil
    }

    public static func contentStartRange(ofBlock blockIndex: Int, in document: NotesDocument,
                                  rendered: AttributedString) -> NSRange? {
        guard document.blocks.indices.contains(blockIndex) else { return nil }
        let text = String(rendered.characters) as NSString
        let lines = lineRanges(text)
        guard lines.indices.contains(blockIndex) else { return nil }
        let line = lines[blockIndex]
        let contentLength = document.blocks[blockIndex].text.utf16.count
        return NSRange(location: NSMaxRange(line) - (line.length > 0 && text.character(at: NSMaxRange(line) - 1) == 10 ? 1 : 0) - contentLength,
                       length: contentLength)
    }

    public static func render(_ document: NotesDocument) -> AttributedString { NotesAttributedString.attributedString(from: document) }
    public static func parseEditorRepresentation(_ attributed: AttributedString) -> NotesDocument { NotesAttributedString.document(from: attributed) }

    private struct Piece { let run: NotesRun }
    private static func selectedRunPieces(in document: NotesDocument, selection: NSRange) -> [Piece] {
        var pieces: [Piece] = []
        let rendered = render(document)
        for blockIndex in document.blocks.indices {
            guard let content = contentStartRange(ofBlock: blockIndex, in: document, rendered: rendered) else { continue }
            var offset = content.location
            for run in document.blocks[blockIndex].runs {
                let range = NSRange(location: offset, length: run.text.utf16.count)
                if NSIntersectionRange(range, selection).length > 0 { pieces.append(Piece(run: run)) }
                offset += range.length
            }
        }
        return pieces
    }

    private static func mutateRuns(in document: NotesDocument, selection: NSRange,
                                   mutation: (inout NotesRun) -> Void) -> NotesEditingResult {
        var result = document
        let rendered = render(document)
        for blockIndex in result.blocks.indices {
            guard let content = contentStartRange(ofBlock: blockIndex, in: document, rendered: rendered) else { continue }
            var global = content.location
            var rebuilt: [NotesRun] = []
            for run in result.blocks[blockIndex].runs {
                let runRange = NSRange(location: global, length: run.text.utf16.count)
                let hit = NSIntersectionRange(runRange, selection)
                if hit.length == 0 { rebuilt.append(run) }
                else {
                    let first = splitRun(run, at: hit.location - global)
                    rebuilt += first.before
                    let second = splitRuns(first.after, at: hit.length)
                    var selected = second.before
                    for i in selected.indices { mutation(&selected[i]) }
                    rebuilt += selected + second.after
                }
                global += runRange.length
            }
            result.blocks[blockIndex].runs = merge(rebuilt)
        }
        return NotesEditingResult(document: result, selection: selection)
    }

    private static func mutateBlocks(in document: NotesDocument, selection: NSRange,
                                     mutation: (inout NotesBlock) -> Void) -> NotesEditingResult {
        var result = document
        for index in selectedBlockIndices(selection, rendered: render(document)) { mutation(&result.blocks[index]) }
        return NotesEditingResult(document: result, selection: adjustedSelection(selection, old: document, new: result))
    }

    private static func selectedBlockIndices(_ selection: NSRange, rendered: AttributedString) -> [Int] {
        let text = String(rendered.characters) as NSString
        return lineRanges(text).indices.filter { index in
            let range = lineRanges(text)[index]
            if selection.length == 0 { return selection.location >= range.location && selection.location <= NSMaxRange(range) }
            return NSIntersectionRange(range, selection).length > 0
        }
    }

    private static func adjustedSelection(_ selection: NSRange, old: NotesDocument, new: NotesDocument) -> NSRange {
        let oldRendered = render(old)
        guard let index = blockIndex(atUTF16Offset: selection.location, in: oldRendered),
              let oldContent = contentStartRange(ofBlock: index, in: old, rendered: oldRendered),
              let newContent = contentStartRange(ofBlock: index, in: new, rendered: render(new)) else { return selection }
        let local = max(0, selection.location - oldContent.location)
        return NSRange(location: newContent.location + min(local, newContent.length), length: selection.length)
    }

    private static func lineRanges(_ text: NSString) -> [NSRange] {
        if text.length == 0 { return [] }
        var result: [NSRange] = [], start = 0
        while start < text.length {
            let found = text.range(of: "\n", options: [], range: NSRange(location: start, length: text.length - start))
            let end = found.location == NSNotFound ? text.length : NSMaxRange(found)
            result.append(NSRange(location: start, length: end - start)); start = end
        }
        if text.character(at: text.length - 1) == 10 {
            result.append(NSRange(location: text.length, length: 0))
        }
        return result
    }

    private static func splitRun(_ run: NotesRun, at offset: Int) -> (before: [NotesRun], after: [NotesRun]) {
        let ns = run.text as NSString, point = min(max(0, offset), ns.length)
        var a = run, b = run; a.text = ns.substring(to: point); b.text = ns.substring(from: point)
        return (a.text.isEmpty ? [] : [a], b.text.isEmpty ? [] : [b])
    }
    private static func splitRuns(_ runs: [NotesRun], at offset: Int) -> (before: [NotesRun], after: [NotesRun]) {
        var before: [NotesRun] = [], after: [NotesRun] = [], remaining = max(0, offset)
        for run in runs {
            if remaining >= run.text.utf16.count { before.append(run); remaining -= run.text.utf16.count }
            else if remaining > 0 { let split = splitRun(run, at: remaining); before += split.before; after += split.after; remaining = 0 }
            else { after.append(run) }
        }
        return (before, after)
    }
    private static func merge(_ runs: [NotesRun]) -> [NotesRun] {
        var result: [NotesRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last, sameStyle(last, run) { result[result.count - 1].text += run.text }
            else { result.append(run) }
        }
        return result
    }
    private static func sameStyle(_ a: NotesRun, _ b: NotesRun) -> Bool {
        a.bold == b.bold && a.italic == b.italic && a.underline == b.underline &&
        a.strikethrough == b.strikethrough && a.link == b.link
    }
    private static func flag(_ format: NotesInlineFormat, on run: NotesRun) -> Bool {
        switch format { case .bold: run.bold; case .italic: run.italic; case .underline: run.underline; case .strikethrough: run.strikethrough }
    }
    private static func set(_ format: NotesInlineFormat, to value: Bool, on run: inout NotesRun) {
        switch format { case .bold: run.bold = value; case .italic: run.italic = value; case .underline: run.underline = value; case .strikethrough: run.strikethrough = value }
    }
}

extension NotesInlineFormat: CaseIterable {}
