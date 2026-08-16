import Foundation

/// A portable, Codable representation of rich task notes: an ordered list of
/// blocks, each holding inline-styled text runs. This is the **durable source of
/// truth** — persisted as JSON in `TaskItem.notesRich` — and is completely
/// independent of whichever editor widget renders it, so formatting and checkbox
/// state round-trip losslessly regardless of the UI layer. A `version` field gives
/// a forward-migration hook if the shape ever changes.
struct NotesDocument: Codable, Equatable, Sendable {
    var version: Int
    var blocks: [NotesBlock]

    init(version: Int = 1, blocks: [NotesBlock] = []) {
        self.version = version
        self.blocks = blocks
    }

    /// Decode leniently so a future field addition can't fail to load an older
    /// stored document (backward compatibility of the on-disk rich payload).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        blocks = try c.decodeIfPresent([NotesBlock].self, forKey: .blocks) ?? []
    }

    /// Whether the document has no visible text at all (all runs empty).
    var isEmpty: Bool {
        blocks.allSatisfy { block in block.runs.allSatisfy { $0.text.isEmpty } }
    }

    /// Plain-text projection for search, snippets, and backups: each block's text
    /// joined by newlines, with **no** markup, list bullets, or checkbox glyphs —
    /// so `SearchService`'s `localizedCaseInsensitiveContains` keeps matching words
    /// inside checklist items.
    var plainText: String {
        blocks.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
    }
}

/// One paragraph-level block. `checked` is only meaningful when `kind == .checkbox`.
struct NotesBlock: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case paragraph, bullet, numbered, checkbox }

    var id: UUID
    var kind: Kind
    var checked: Bool
    var runs: [NotesRun]

    init(id: UUID = UUID(), kind: Kind = .paragraph, checked: Bool = false, runs: [NotesRun] = []) {
        self.id = id
        self.kind = kind
        self.checked = checked
        self.runs = runs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .paragraph
        checked = try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        runs = try c.decodeIfPresent([NotesRun].self, forKey: .runs) ?? []
    }

    /// The concatenated text of this block (no markers).
    var text: String { runs.map(\.text).joined() }
}

/// A run of text sharing the same inline styling.
struct NotesRun: Codable, Equatable, Sendable {
    var text: String
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var strikethrough: Bool
    var link: URL?

    init(text: String, bold: Bool = false, italic: Bool = false,
         underline: Bool = false, strikethrough: Bool = false, link: URL? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.link = link
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        link = try c.decodeIfPresent(URL.self, forKey: .link)
    }

    var hasStyle: Bool { bold || italic || underline || strikethrough || link != nil }
}
