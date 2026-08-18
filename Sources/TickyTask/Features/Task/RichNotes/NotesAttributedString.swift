import AppKit
import SwiftUI

struct NotesBoldAttribute: CodableAttributedStringKey {
    typealias Value = Bool
    static let name = "com.tickytask.notes.bold"
}

struct NotesItalicAttribute: CodableAttributedStringKey {
    typealias Value = Bool
    static let name = "com.tickytask.notes.italic"
}

enum NotesAttributedString {
    static func attributedString(from document: NotesDocument) -> AttributedString {
        var result = AttributedString()
        var numberedCounts: [Int: Int] = [:]
        var previousWasNumbered = false

        for (index, block) in document.blocks.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            let start = result.endIndex
            let spaces = String(repeating: " ", count: max(0, block.indent) * 2)
            switch block.kind {
            case .paragraph:
                previousWasNumbered = false
            case .bullet, .checkbox:
                previousWasNumbered = false
                result.append(AttributedString(spaces + "• "))
            case .numbered:
                if !previousWasNumbered { numberedCounts.removeAll() }
                // Returning to a shallower level restarts any deeper sub-list numbering.
                numberedCounts = numberedCounts.filter { $0.key <= block.indent }
                let ordinal = (numberedCounts[block.indent] ?? 0) + 1
                numberedCounts[block.indent] = ordinal
                previousWasNumbered = true
                result.append(AttributedString(spaces + "\(ordinal). "))
            }

            for run in block.runs {
                var rendered = AttributedString(run.text)
                var font = Font.body
                if run.bold { font = font.bold() }
                if run.italic { font = font.italic() }
                rendered.font = font
                rendered[NotesBoldAttribute.self] = run.bold
                rendered[NotesItalicAttribute.self] = run.italic
                if run.underline { rendered.underlineStyle = .single }
                if run.strikethrough { rendered.strikethroughStyle = .single }
                rendered.link = run.link
                result.append(rendered)
            }
            let end = result.endIndex
            if start < end {
                result[start..<end][NotesBlockIDKey.self] = block.id
                result[start..<end][NotesBlockKindKey.self] = block.kind.rawValue
                result[start..<end][NotesBlockIndentKey.self] = block.indent
                result[start..<end][NotesBlockCheckedKey.self] = block.checked
            }
        }
        return result
    }

    static func document(from string: AttributedString) -> NotesDocument {
        guard !string.characters.isEmpty else { return NotesDocument() }
        let nsString = NSAttributedString(string)
        var blocks: [NotesBlock] = []
        var lineStart = string.startIndex

        while true {
            let newline = string.characters[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? string.endIndex
            let line = AttributedString(string[lineStart..<lineEnd])
            let firstRun = line.runs.first
            let rawKind = firstRun?[NotesBlockKindKey.self]
            let kind = rawKind.flatMap(NotesBlock.Kind.init(rawValue:)) ?? .paragraph
            let id = firstRun?[NotesBlockIDKey.self] ?? UUID()
            let indent = firstRun?[NotesBlockIndentKey.self] ?? 0
            let checked = firstRun?[NotesBlockCheckedKey.self] ?? false
            let hasMetadata = rawKind != nil
            let rawText = String(line.characters)
            var markerLength = 0
            if hasMetadata, kind != .paragraph,
               let markerRange = rawText.range(of: #"^ *(• |\d+\. )"#, options: .regularExpression) {
                markerLength = rawText.distance(from: rawText.startIndex, to: markerRange.upperBound)
            }
            let contentStart = line.characters.index(line.startIndex, offsetBy: markerLength)
            let content = AttributedString(line[contentStart..<line.endIndex])
            let lineUTF16Start = String(string.characters[..<lineStart]).utf16.count
            let markerUTF16 = String(rawText.prefix(markerLength)).utf16.count
            var runs: [NotesRun] = []
            for run in content.runs {
                let text = String(content[run.range].characters)
                guard !text.isEmpty else { continue }
                let local = content.characters.distance(from: content.startIndex, to: run.range.lowerBound)
                let fallback = lineUTF16Start + markerUTF16 + String(content.characters.prefix(local)).utf16.count
                let traits = fallback < nsString.length
                    ? (nsString.attribute(.font, at: fallback, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                    : []
                runs.append(NotesRun(text: text,
                                     bold: run[NotesBoldAttribute.self] == true || traits.contains(.bold),
                                     italic: run[NotesItalicAttribute.self] == true || traits.contains(.italic),
                                     underline: run.underlineStyle != nil,
                                     strikethrough: run.strikethroughStyle != nil,
                                     link: run.link))
            }
            blocks.append(NotesBlock(id: id, kind: kind, checked: checked, indent: indent, runs: runs))
            guard let newline else { break }
            lineStart = string.characters.index(after: newline)
        }
        return NotesDocument(blocks: blocks)
    }
}
