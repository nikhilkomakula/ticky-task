import AppKit
import Foundation

struct NotesBlockIDKey: CodableAttributedStringKey {
    typealias Value = UUID
    static let name = "notesBlockID"
    static let inheritedByAddedText = false
    static let invalidationConditions: Set<AttributedString.AttributeInvalidationCondition> = []
}

struct NotesBlockKindKey: CodableAttributedStringKey {
    typealias Value = String
    static let name = "notesBlockKind"
    static let inheritedByAddedText = false
    static let invalidationConditions: Set<AttributedString.AttributeInvalidationCondition> = []
}

struct NotesBlockIndentKey: CodableAttributedStringKey {
    typealias Value = Int
    static let name = "notesBlockIndent"
    static let inheritedByAddedText = false
    static let invalidationConditions: Set<AttributedString.AttributeInvalidationCondition> = []
}

/// Retains the legacy checkbox state even though checkbox blocks currently share
/// the bullet marker in the editor representation.
struct NotesBlockCheckedKey: CodableAttributedStringKey {
    typealias Value = Bool
    static let name = "notesBlockChecked"
    static let inheritedByAddedText = false
    static let invalidationConditions: Set<AttributedString.AttributeInvalidationCondition> = []
}

extension AttributeScopes {
    struct NotesAttributes: AttributeScope {
        let notesBlockID: NotesBlockIDKey
        let notesBlockKind: NotesBlockKindKey
        let notesBlockIndent: NotesBlockIndentKey
        let notesBlockChecked: NotesBlockCheckedKey
    }
    var notes: NotesAttributes.Type { NotesAttributes.self }
}
