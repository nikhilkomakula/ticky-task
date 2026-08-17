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
        for (blockIndex, block) in document.blocks.enumerated() {
            if blockIndex > 0 { result.append(AttributedString("\n")) }

            switch block.kind {
            case .paragraph:
                break
            case .bullet:
                result.append(AttributedString("• "))
            case .numbered:
                result.append(AttributedString("\(number(for: blockIndex, in: document.blocks)). "))
            case .checkbox:
                // v0.1.9 checkbox blocks remain decodable, but are presented as
                // ordinary bullets now that checklist editing has been removed.
                result.append(AttributedString("• "))
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
        }
        return result
    }

    static func document(from string: AttributedString) -> NotesDocument {
        let nsString = NSAttributedString(string)
        let fullText = String(string.characters)
        let lines = fullText.split(separator: "\n", omittingEmptySubsequences: false)
        var blocks: [NotesBlock] = []
        var utf16Offset = 0
        var characterOffset = 0

        for lineSlice in lines {
            let rawLine = String(lineSlice)
            let marker = marker(in: rawLine)
            let content = String(rawLine.dropFirst(marker.length))
            let contentUTF16Length = content.utf16.count
            let nsRange = NSRange(location: utf16Offset + String(rawLine.prefix(marker.length)).utf16.count,
                                  length: contentUTF16Length)
            let lineStart = string.characters.index(string.startIndex, offsetBy: characterOffset)
            let contentStart = string.characters.index(lineStart, offsetBy: marker.length)
            let contentEnd = string.characters.index(contentStart, offsetBy: content.count)
            let attributedLine = AttributedString(string[contentStart..<contentEnd])
            var runs: [NotesRun] = []

            for run in attributedLine.runs {
                let text = String(attributedLine[run.range].characters)
                guard !text.isEmpty else { continue }
                let localStart = attributedLine.characters.distance(from: attributedLine.startIndex, to: run.range.lowerBound)
                let fallbackRange = NSRange(location: nsRange.location + String(content.prefix(localStart)).utf16.count,
                                            length: text.utf16.count)
                let traits = (fallbackRange.length > 0
                    ? nsString.attribute(.font, at: fallbackRange.location, effectiveRange: nil) as? NSFont
                    : nil)?.fontDescriptor.symbolicTraits ?? []
                runs.append(NotesRun(
                    text: text,
                    bold: run[NotesBoldAttribute.self] == true || traits.contains(.bold),
                    italic: run[NotesItalicAttribute.self] == true || traits.contains(.italic),
                    underline: run.underlineStyle != nil,
                    strikethrough: run.strikethroughStyle != nil,
                    link: run.link
                ))
            }

            blocks.append(NotesBlock(kind: marker.kind,
                                     checked: marker.checked, runs: runs))
            utf16Offset += rawLine.utf16.count + 1
            characterOffset += rawLine.count + 1
        }
        return NotesDocument(blocks: blocks)
    }

    private static func number(for index: Int, in blocks: [NotesBlock]) -> Int {
        var value = 0
        for block in blocks.prefix(index + 1) {
            value = block.kind == .numbered ? value + 1 : 0
        }
        return value
    }

    private static func marker(in line: String) -> (kind: NotesBlock.Kind, checked: Bool, length: Int) {
        if line.hasPrefix("• ") { return (.bullet, false, 2) }
        if let range = line.range(of: #"^\d+\. "#, options: .regularExpression) {
            return (.numbered, false, line.distance(from: line.startIndex, to: range.upperBound))
        }
        return (.paragraph, false, 0)
    }

}
