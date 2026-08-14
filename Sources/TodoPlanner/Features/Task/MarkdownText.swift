import SwiftUI

/// Renders a Markdown string as attributed text (bold, italic, links, code,
/// line breaks). Used for the task-notes preview. Block-level constructs render
/// inline; a fuller renderer can come later if needed.
struct MarkdownText: View {
    let markdown: String

    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("No details")
                .italic()
                .foregroundStyle(.secondary)
        } else if let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attributed)
        } else {
            Text(markdown)
        }
    }
}
