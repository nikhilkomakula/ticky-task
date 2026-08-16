import Foundation

/// Pure, `nonisolated` conversions for rich notes — no SwiftUI/SwiftData, so it's
/// trivially unit-testable and safe under `SWIFT_STRICT_CONCURRENCY: targeted`.
/// Handles JSON (de)serialization of `NotesDocument`, legacy-Markdown import, and
/// the "resolve the document for a task" rule.
enum NotesCodec {
    // MARK: JSON persistence

    static func encode(_ document: NotesDocument) throws -> Data {
        try JSONEncoder().encode(document)
    }

    static func decode(_ data: Data) throws -> NotesDocument {
        try JSONDecoder().decode(NotesDocument.self, from: data)
    }

    // MARK: Resolve

    /// The document to edit/render for a task: decode the rich payload when present
    /// and non-empty, otherwise fall back to importing the legacy Markdown `notes`
    /// string (so pre-0.1.9 tasks keep rendering until first edit). Takes the raw
    /// fields (not the model) to stay pure and testable.
    static func resolved(fromRich data: Data?, markdown: String) -> NotesDocument {
        if let data, !data.isEmpty, let doc = try? decode(data), !doc.blocks.isEmpty {
            return doc
        }
        return document(fromMarkdown: markdown)
    }

    // MARK: Legacy Markdown import

    /// Convert a legacy Markdown notes string into a `NotesDocument`. Line-level
    /// prefixes become block kinds (`- [ ]`/`- [x]` → checkbox, `-`/`*` → bullet,
    /// `1.` → numbered); inline `**bold**`/`*italic*`/`~~strike~~`/`[link](url)`
    /// become styled runs via `AttributedString(markdown:)`'s inline intents.
    static func document(fromMarkdown markdown: String) -> NotesDocument {
        guard !markdown.isEmpty else { return NotesDocument() }
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [NotesBlock] = []
        for rawLine in lines {
            var line = rawLine
            var kind: NotesBlock.Kind = .paragraph
            var checked = false

            // Checkbox must be tested before the plain-bullet rule ("- [ ]" also
            // starts with "- ").
            if let m = line.range(of: #"^\s*[-*] \[[ xX]\]\s?"#, options: .regularExpression) {
                checked = line[m].contains("x") || line[m].contains("X")
                kind = .checkbox
                line.removeSubrange(m)
            } else if let m = line.range(of: #"^\s*[-*]\s+"#, options: .regularExpression) {
                kind = .bullet
                line.removeSubrange(m)
            } else if let m = line.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) {
                kind = .numbered
                line.removeSubrange(m)
            }

            blocks.append(NotesBlock(kind: kind, checked: checked, runs: runs(fromInlineMarkdown: line)))
        }
        return NotesDocument(blocks: blocks)
    }

    /// Parse a single line's inline Markdown into styled runs. Falls back to a
    /// single plain run if parsing fails or yields nothing.
    static func runs(fromInlineMarkdown line: String) -> [NotesRun] {
        guard !line.isEmpty else { return [] }
        guard let attributed = try? AttributedString(
            markdown: line,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return [NotesRun(text: line)]
        }
        var runs: [NotesRun] = []
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            guard !text.isEmpty else { continue }
            let intent = run.inlinePresentationIntent ?? []
            runs.append(NotesRun(
                text: text,
                bold: intent.contains(.stronglyEmphasized),
                italic: intent.contains(.emphasized),
                underline: false,
                strikethrough: intent.contains(.strikethrough),
                link: run.link
            ))
        }
        return runs.isEmpty ? [NotesRun(text: line)] : runs
    }
}
