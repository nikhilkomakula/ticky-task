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

    /// Checkbox blocks extracted from the current document.
    @State private var checkboxBlocks: [(n: Int, id: UUID, checked: Bool)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                formatButton("Bold", systemImage: "bold", id: "notes-bold") { a in
                    let bold = !(a[NotesBoldAttribute.self] ?? false)
                    a[NotesBoldAttribute.self] = bold
                    a.font = Self.font(bold: bold, italic: a[NotesItalicAttribute.self] ?? false)
                }
                formatButton("Italic", systemImage: "italic", id: "notes-italic") { a in
                    let italic = !(a[NotesItalicAttribute.self] ?? false)
                    a[NotesItalicAttribute.self] = italic
                    a.font = Self.font(bold: a[NotesBoldAttribute.self] ?? false, italic: italic)
                }
                formatButton("Underline", systemImage: "underline", id: "notes-underline") { a in
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
                listButton("Checklist", systemImage: "checklist", id: "notes-checklist", kind: .checkbox)
            }
            .buttonStyle(.borderless)

            checkboxToggles

            TextEditor(text: $text, selection: $selection)
                .font(.body)
                .frame(minHeight: 120)
                .accessibilityIdentifier("editor-notes")
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "tickytask", url.host == "toggle",
                          let id = UUID(uuidString: url.lastPathComponent) else { return .systemAction }
                    var document = NotesAttributedString.document(from: text)
                    guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return .discarded }
                    document.blocks[index].checked.toggle()
                    text = NotesAttributedString.attributedString(from: document)
                    return .handled
                })
        }
        .alert("Add Link", isPresented: $showingLinkPrompt) {
            TextField("https://example.com", text: $linkText)
            Button("Apply") { applyLink() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: text, initial: true) { _, newValue in
            let doc = NotesAttributedString.document(from: newValue)
            checkboxBlocks = doc.blocks
                .filter { $0.kind == .checkbox }
                .enumerated()
                .map { (n: $0, id: $1.id, checked: $1.checked) }
        }
    }

    /// Accessible toggle buttons for each checkbox block.
    /// macOS 26 TextEditor link-tap does not fire openURL in edit mode;
    /// these buttons are the reliable toggle surface.
    @ViewBuilder
    var checkboxToggles: some View {
        if !checkboxBlocks.isEmpty {
            HStack(spacing: 6) {
                Text("Toggle:").font(.caption).foregroundStyle(.secondary)
                ForEach(checkboxBlocks, id: \.id) { item in
                    Button(item.checked ? "\u{2611}" : "\u{2610}") {
                        var doc = NotesAttributedString.document(from: text)
                        if let idx = doc.blocks.firstIndex(where: { $0.id == item.id }) {
                            doc.blocks[idx].checked.toggle()
                            text = NotesAttributedString.attributedString(from: doc)
                        }
                    }
                    .accessibilityIdentifier("notes-checkbox-\(item.n)")
                    .accessibilityLabel(item.checked ? "Uncheck item \(item.n + 1)" : "Check item \(item.n + 1)")
                    .buttonStyle(.borderless)
                    .font(.body)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func formatButton(_ title: String, systemImage: String, id: String,
                              action: @escaping (inout AttributeContainer) -> Void) -> some View {
        Button {
            text.transformAttributes(in: &selection, body: action)
        } label: { Image(systemName: systemImage) }
        .help(title).accessibilityLabel(title).accessibilityIdentifier(id)
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
                if document.blocks[index].kind != .checkbox { document.blocks[index].checked = false }
            }
            text = NotesAttributedString.attributedString(from: document)
        } label: { Image(systemName: systemImage) }
        .help(title).accessibilityLabel(title).accessibilityIdentifier(id)
    }

    private func applyLink() {
        guard let url = URL(string: linkText), url.scheme != nil else { return }
        text.transformAttributes(in: &linkSelection) { attributes in attributes.link = url }
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
