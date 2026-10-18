import Foundation

/// The extraction response from the LLM (schema version 1).
struct AvailabilityExtractionContract: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let entries: [ExtractionEntry]
    let unresolved: [UnresolvedEntry]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, entries, unresolved, warnings
    }

    struct ExtractionEntry: Codable, Equatable, Sendable {
        let sourceRef: String
        let personText: String
        let startDate: String  // yyyy-MM-dd
        let endDate: String    // yyyy-MM-dd
        let portion: String    // full, am, pm
        let kind: String       // pto, sick, personal, training, other
        let dateText: String   // Original text describing the dates
        let evidence: String   // The text/detail from the source
        let confidence: String // high, medium, low
        let issues: [String]

        enum CodingKeys: String, CodingKey {
            case sourceRef, personText, startDate, endDate, portion, kind, dateText, evidence, confidence, issues
        }
    }

    struct UnresolvedEntry: Codable, Equatable, Sendable {
        let sourceRef: String
        let evidence: String
        let issues: [String]

        enum CodingKeys: String, CodingKey {
            case sourceRef, evidence, issues
        }
    }
}

/// Validated and decoded extraction entry, ready for person matching.
struct ValidatedExtractionEntry: Equatable, Sendable {
    let sourceRef: String
    let personText: String
    let startDate: KanbanDay
    let endDate: KanbanDay
    let portion: KanbanTimeOffPortion
    let kind: KanbanTimeOffKind
    let dateText: String
    let evidence: String
    let confidence: Confidence
    let issues: [String]

    enum Confidence: String, Sendable {
        case high, medium, low
    }
}

/// Result of contract validation: the entries passed validation and the issues found.
struct ValidationResult: Sendable {
    let entries: [ValidatedExtractionEntry]
    let unresolved: [UnresolvedEntry]
    let issues: [String]

    struct UnresolvedEntry: Sendable {
        let sourceRef: String
        let evidence: String
        let issues: [String]
    }
}

/// One proposal after person matching.
struct AvailabilityProposal: Equatable, Sendable {
    let entry: ValidatedExtractionEntry
    let classification: Classification

    enum Classification: Equatable, Sendable {
        /// No existing entry overlaps.
        case new
        /// Identical meaning (person, dates, portion, kind).
        case alreadyRecorded(id: UUID)
        /// Shares one or more half-day slots with an existing entry.
        case overlapsExisting(existing: [KanbanTimeOff], preview: [KanbanTimeOff])
        /// Person name couldn't be resolved to one person; a picker is needed.
        case unmatchedName(suggestions: [KanbanPerson])
        /// Missing or ambiguous year, ambiguous half day on a multi-day range, invalid dates.
        case needsReview(reason: String)
    }

    var isSelected: Bool = false
    /// When classification is .unmatchedName, the user's choice; otherwise ignored.
    var resolvedPerson: KanbanPerson? = nil
    /// When resolvedPerson is chosen, whether to remember the personText as an alias.
    var rememberAlias: Bool = false

    init(entry: ValidatedExtractionEntry, classification: Classification) {
        self.entry = entry
        self.classification = classification
    }
}

/// The final delta to apply, after user selections.
struct ApplyableAvailabilityDelta: Sendable {
    let delta: KanbanAvailabilityDelta
    let summary: String
    let affectedPeople: [KanbanPerson]
    /// The set of boards affected by this delta.
    let affectedBoards: Set<UUID>
}
