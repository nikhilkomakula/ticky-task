import SwiftUI

struct RichNotesEditor: View {
    @Binding var text: AttributedString
    @State private var selection = AttributedTextSelection()
    @State private var showingLinkPrompt = false
    @State private var linkText = "https://"
    /// The selection captured when the link button was pressed — the link alert
    /// steals focus from the editor, so applying against the live `selection` could
    /// target an empty/stale range.
    @State private var linkSelection = AttributedTextSelection()

    private var document: NotesDocument { NotesEditingEngine.parseEditorRepresentation(text) }
    private var renderedDocument: AttributedString { NotesEditingEngine.render(document) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                formatButton("Bold", systemImage: "bold", id: "notes-bold", shortcut: "b", format: .bold)
                formatButton("Italic", systemImage: "italic", id: "notes-italic", shortcut: "i", format: .italic)
                formatButton("Underline", systemImage: "underline", id: "notes-underline", shortcut: "u", format: .underline)
                formatButton("Strikethrough", systemImage: "strikethrough", id: "notes-strike", format: .strikethrough)
                listButton("Bulleted list", systemImage: "list.bullet", id: "notes-bullet", kind: .bullet)
                listButton("Numbered list", systemImage: "list.number", id: "notes-numbered", kind: .numbered)
                Button {
                    linkText = "https://"
                    linkSelection = selection
                    showingLinkPrompt = true
                } label: { Image(systemName: "link") }
                    .help("Link").accessibilityLabel("Link").accessibilityIdentifier("notes-link")
            }
            .buttonStyle(.borderless)

            TextEditor(text: $text, selection: $selection)
                .font(.body)
                .frame(minHeight: 120)
                .accessibilityIdentifier("editor-notes")
                .onKeyPress(.return) { continueList() }
                .onKeyPress(.tab, phases: .down) { keyPress in
                    adjustIndent(outdent: keyPress.modifiers.contains(.shift))
                }
        }
        .alert("Add Link", isPresented: $showingLinkPrompt) {
            TextField("https://example.com", text: $linkText)
            Button("Apply") { applyLink() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func formatButton(_ title: String, systemImage: String, id: String,
                              shortcut: KeyEquivalent? = nil,
                              format: NotesInlineFormat) -> some View {
        let button = Button {
            let range = nsRange(from: selection, in: text)
            let result = NotesEditingEngine.toggleInlineFormat(format, in: document, selection: range)
            apply(result)
        } label: { Image(systemName: systemImage) }
        .help(title).accessibilityLabel(title).accessibilityIdentifier(id)
        .accessibilityValue(isFormatActive(title) ? "On" : "Off")
        if let shortcut {
            button.keyboardShortcut(shortcut, modifiers: .command)
        } else {
            button
        }
    }

    private func listButton(_ title: String, systemImage: String, id: String,
                            kind: NotesBlock.Kind) -> some View {
        Button {
            let result = NotesEditingEngine.toggleList(kind: kind, in: document,
                                                       selection: nsRange(from: selection, in: text))
            apply(result)
        } label: { Image(systemName: systemImage) }
        .help(title).accessibilityLabel(title).accessibilityIdentifier(id)
    }

    private func applyLink() {
        // applyLink validates the URL (http/https + host) and returns nil for
        // anything it rejects, so no separate pre-check is needed.
        let range = nsRange(from: linkSelection, in: text)
        guard let result = NotesEditingEngine.applyLink(linkText, in: document, selection: range) else { return }
        apply(result)
    }

    /// On Return inside a list: continue the list with a new empty item of the same
    /// kind (numbered markers renumber automatically on re-render), or — if the
    /// current item is empty — end the list by turning it into a paragraph. All
    /// indexing is clamped/guarded so this can never crash the editor. Only the
    /// common "Return at the end of a line" flow moves the caret; text after a
    /// mid-line caret simply stays on the current item.
    private func continueList() -> KeyPress.Result {
        let range = nsRange(from: selection, in: text)
        guard range.length == 0,
              let result = NotesEditingEngine.continueList(in: document,
                  caretOffsetInRendered: range.location, rendered: renderedDocument) else { return .ignored }
        apply(result)
        return .handled
    }

    private func adjustIndent(outdent: Bool) -> KeyPress.Result {
        let range = nsRange(from: selection, in: text)
        // Consume Tab within the notes body (never a stray tab char or focus jump).
        // Tab indents/nests a list item (or promotes a paragraph to a bullet);
        // Shift-Tab outdents; both are no-ops the engine leaves unchanged elsewhere.
        guard let index = NotesEditingEngine.blockIndex(atUTF16Offset: range.location, in: text),
              document.blocks.indices.contains(index) else { return .ignored }
        let result = outdent
            ? NotesEditingEngine.outdentBlocks(in: document, selection: range)
            : NotesEditingEngine.indentBlocks(in: document, selection: range)
        apply(result)
        return .handled
    }

    private func nsRange(from selection: AttributedTextSelection, in attributed: AttributedString) -> NSRange {
        switch selection.indices(in: attributed) {
        case let .insertionPoint(index):
            return NSRange(location: String(attributed.characters[..<index]).utf16.count, length: 0)
        case let .ranges(ranges):
            guard let first = ranges.ranges.first, let last = ranges.ranges.last else {
                return NSRange(location: 0, length: 0)
            }
            let location = String(attributed.characters[..<first.lowerBound]).utf16.count
            let end = String(attributed.characters[..<last.upperBound]).utf16.count
            return NSRange(location: location, length: end - location)
        }
    }

    private func apply(_ result: NotesEditingResult) {
        text = NotesEditingEngine.render(result.document)
        let ns = String(text.characters) as NSString
        let location = min(max(0, result.selection.location), ns.length)
        let plain = String(text.characters)
        let stringIndex = String.Index(utf16Offset: location, in: plain)
        guard let index = AttributedString.Index(stringIndex, within: text) else { return }
        let endLocation = min(location + result.selection.length, ns.length)
        guard endLocation > location else {
            selection = AttributedTextSelection(insertionPoint: index)
            return
        }
        let endStringIndex = String.Index(utf16Offset: endLocation, in: plain)
        guard let endIndex = AttributedString.Index(endStringIndex, within: text) else { return }
        selection = AttributedTextSelection(range: index..<endIndex)
    }

    private func isFormatActive(_ title: String) -> Bool {
        let attributes = Array(selection.attributes(in: text))
        guard !attributes.isEmpty else { return false }
        return attributes.allSatisfy { attributes in
            switch title {
            case "Bold": attributes[NotesBoldAttribute.self] == true
            case "Italic": attributes[NotesItalicAttribute.self] == true
            case "Underline": attributes.underlineStyle != nil
            case "Strikethrough": attributes.strikethroughStyle != nil
            default: false
            }
        }
    }

}
