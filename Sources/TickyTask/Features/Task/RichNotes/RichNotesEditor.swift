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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                formatButton("Bold", systemImage: "bold", id: "notes-bold", shortcut: "b") { a in
                    let bold = !(a[NotesBoldAttribute.self] ?? false)
                    a[NotesBoldAttribute.self] = bold
                    a.font = Self.font(bold: bold, italic: a[NotesItalicAttribute.self] ?? false)
                }
                formatButton("Italic", systemImage: "italic", id: "notes-italic", shortcut: "i") { a in
                    let italic = !(a[NotesItalicAttribute.self] ?? false)
                    a[NotesItalicAttribute.self] = italic
                    a.font = Self.font(bold: a[NotesBoldAttribute.self] ?? false, italic: italic)
                }
                formatButton("Underline", systemImage: "underline", id: "notes-underline", shortcut: "u") { a in
                    a.underlineStyle = a.underlineStyle == nil ? .single : nil
                }
                formatButton("Strikethrough", systemImage: "strikethrough", id: "notes-strike") { a in
                    a.strikethroughStyle = a.strikethroughStyle == nil ? .single : nil
                }
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
                              action: @escaping (inout AttributeContainer) -> Void) -> some View {
        let button = Button {
            text.transformAttributes(in: &selection, body: action)
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
            var document = NotesAttributedString.document(from: text)
            if document.blocks.isEmpty { document.blocks = [NotesBlock()] }
            // Toggle across the note: if every block is already this kind, revert to
            // plain paragraphs; otherwise convert them all. (v1 applies to the whole
            // note; per-paragraph targeting is a planned enhancement — it needs the
            // macOS 26 selection-range API, whose bare-cursor behavior is unverified.)
            let allAlready = document.blocks.allSatisfy { $0.kind == kind }
            for index in document.blocks.indices {
                document.blocks[index].kind = allAlready ? .paragraph : kind
                document.blocks[index].checked = false
            }
            text = NotesAttributedString.attributedString(from: document)
            selection = AttributedTextSelection(insertionPoint: text.endIndex)
        } label: { Image(systemName: systemImage) }
        .help(title).accessibilityLabel(title).accessibilityIdentifier(id)
    }

    private func applyLink() {
        // Only allow web links — never file:, javascript:, or other schemes that
        // could be opened from the notes view.
        guard let url = URL(string: linkText),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        text.transformAttributes(in: &linkSelection) { attributes in attributes.link = url }
    }

    /// On Return inside a list: continue the list with a new empty item of the same
    /// kind (numbered markers renumber automatically on re-render), or — if the
    /// current item is empty — end the list by turning it into a paragraph. All
    /// indexing is clamped/guarded so this can never crash the editor. Only the
    /// common "Return at the end of a line" flow moves the caret; text after a
    /// mid-line caret simply stays on the current item.
    private func continueList() -> KeyPress.Result {
        guard case let .insertionPoint(caret) = selection.indices(in: text) else { return .ignored }
        let caretOffset = text.characters.distance(from: text.startIndex, to: caret)
        var document = NotesAttributedString.document(from: text)
        let blockIndex = String(text.characters.prefix(caretOffset)).filter { $0 == "\n" }.count
        guard document.blocks.indices.contains(blockIndex) else { return .ignored }
        let kind = document.blocks[blockIndex].kind
        guard kind == .bullet || kind == .numbered else { return .ignored }

        let targetBlock: Int
        if document.blocks[blockIndex].text.isEmpty {
            document.blocks[blockIndex].kind = .paragraph   // empty item → end the list
            targetBlock = blockIndex
        } else {
            document.blocks.insert(NotesBlock(kind: kind, runs: []), at: blockIndex + 1)
            targetBlock = blockIndex + 1
        }

        text = NotesAttributedString.attributedString(from: document)
        moveCaretToContentStart(ofBlock: targetBlock, in: document)
        return .handled
    }

    /// Place the caret just after the marker of `document.blocks[index]`, computed
    /// against the freshly-assigned `text` with fully-guarded indexing.
    private func moveCaretToContentStart(ofBlock index: Int, in document: NotesDocument) {
        let lines = String(text.characters).components(separatedBy: "\n")
        guard index < lines.count, document.blocks.indices.contains(index) else {
            selection = AttributedTextSelection(insertionPoint: text.endIndex)
            return
        }
        var offset = 0
        for i in 0..<index { offset += lines[i].count + 1 }   // +1 for each joining newline
        offset += max(0, lines[index].count - document.blocks[index].text.count) // skip the marker
        offset = min(max(0, offset), text.characters.count)
        let caret = text.characters.index(text.startIndex, offsetBy: offset)
        selection = AttributedTextSelection(insertionPoint: caret)
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

    /// A body font with the requested combination of bold/italic traits, so
    /// toggling one style never drops the other from the on-screen font.
    private static func font(bold: Bool, italic: Bool) -> Font {
        var font = Font.body
        if bold { font = font.bold() }
        if italic { font = font.italic() }
        return font
    }
}
