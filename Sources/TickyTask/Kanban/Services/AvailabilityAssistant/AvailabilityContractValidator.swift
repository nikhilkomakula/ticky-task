import Foundation

enum AvailabilityContractValidator {
    enum Error: LocalizedError, Sendable {
        case schemaVersionMismatch(got: Int)
        case malformedJSON(String)
        case entriesNotArray
        case unresolvedNotArray
        case warningsNotArray
        case entryValidationFailed(String)

        var errorDescription: String? {
            switch self {
            case .schemaVersionMismatch(let got):
                return "Schema version \(got) is not supported (expected 1)"
            case .malformedJSON(let msg):
                return "Invalid JSON: \(msg)"
            case .entriesNotArray:
                return "Field 'entries' must be an array"
            case .unresolvedNotArray:
                return "Field 'unresolved' must be an array"
            case .warningsNotArray:
                return "Field 'warnings' must be an array"
            case .entryValidationFailed(let msg):
                return msg
            }
        }
    }

    /// Decode and validate the JSON response from the LLM.
    static func validate(_ data: Data) -> Result<ValidationResult, Error> {
        do {
            let decoder = JSONDecoder()
            let contract = try decoder.decode(AvailabilityExtractionContract.self, from: data)

            guard contract.schemaVersion == 1 else {
                return .failure(.schemaVersionMismatch(got: contract.schemaVersion))
            }

            var validatedEntries: [ValidatedExtractionEntry] = []
            var issues: [String] = []

            for (index, entry) in contract.entries.enumerated() {
                switch validateEntry(entry, index: index) {
                case .success(let validated):
                    validatedEntries.append(validated)
                case .failure(let entryIssue):
                    issues.append(entryIssue.errorDescription ?? "Unknown error")
                }
            }

            var validatedUnresolved: [ValidationResult.UnresolvedEntry] = []
            for unresolvedEntry in contract.unresolved {
                if validateSourceRef(unresolvedEntry.sourceRef) {
                    validatedUnresolved.append(.init(sourceRef: unresolvedEntry.sourceRef,
                                                     evidence: unresolvedEntry.evidence,
                                                     issues: unresolvedEntry.issues))
                } else {
                    issues.append("Unresolved entry has unknown sourceRef: '\(unresolvedEntry.sourceRef)'")
                }
            }

            let allWarnings = contract.warnings + issues

            return .success(.init(entries: validatedEntries, unresolved: validatedUnresolved, issues: allWarnings))
        } catch let error as DecodingError {
            return .failure(.malformedJSON(error.localizedDescription))
        } catch {
            return .failure(.malformedJSON(error.localizedDescription))
        }
    }

    private static func validateEntry(_ entry: AvailabilityExtractionContract.ExtractionEntry,
                                      index: Int) -> Result<ValidatedExtractionEntry, Error> {
        var issues: [String] = []

        // Validate sourceRef
        guard validateSourceRef(entry.sourceRef) else {
            return .failure(.entryValidationFailed("Entry \(index): unknown sourceRef '\(entry.sourceRef)'"))
        }

        // Validate dates
        guard let startDate = dateFromString(entry.startDate) else {
            return .failure(.entryValidationFailed("Entry \(index): invalid startDate '\(entry.startDate)' (expected YYYY-MM-DD)"))
        }

        guard let endDate = dateFromString(entry.endDate) else {
            return .failure(.entryValidationFailed("Entry \(index): invalid endDate '\(entry.endDate)' (expected YYYY-MM-DD)"))
        }

        guard startDate <= endDate else {
            return .failure(.entryValidationFailed("Entry \(index): endDate before startDate"))
        }

        // Validate portion
        guard let portion = KanbanTimeOffPortion(rawValue: entry.portion) else {
            return .failure(.entryValidationFailed("Entry \(index): invalid portion '\(entry.portion)' (must be full, am, or pm)"))
        }

        // AM/PM only on single days
        if portion != .full && startDate != endDate {
            issues.append("Entry \(index): portion '\(entry.portion)' only valid for single-day absences")
        }

        // Validate kind
        guard let kind = KanbanTimeOffKind(rawValue: entry.kind) else {
            return .failure(.entryValidationFailed("Entry \(index): invalid kind '\(entry.kind)'"))
        }

        // Check string bounds
        let maxLength = 500
        if entry.personText.count > maxLength {
            return .failure(.entryValidationFailed("Entry \(index): personText exceeds \(maxLength) characters"))
        }
        if entry.evidence.count > maxLength {
            return .failure(.entryValidationFailed("Entry \(index): evidence exceeds \(maxLength) characters"))
        }

        // Validate confidence
        guard ["high", "medium", "low"].contains(entry.confidence) else {
            return .failure(.entryValidationFailed("Entry \(index): invalid confidence '\(entry.confidence)'"))
        }
        let confidence = ValidatedExtractionEntry.Confidence(rawValue: entry.confidence)!

        let validated = ValidatedExtractionEntry(
            sourceRef: entry.sourceRef,
            personText: entry.personText,
            startDate: startDate,
            endDate: endDate,
            portion: portion,
            kind: kind,
            dateText: entry.dateText,
            evidence: entry.evidence,
            confidence: confidence,
            issues: issues + entry.issues
        )

        if issues.isEmpty {
            return .success(validated)
        } else {
            return .success(validated)  // Include with issues, not reject
        }
    }

    private static func dateFromString(_ str: String) -> KanbanDay? {
        let components = str.split(separator: "-")
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]) else {
            return nil
        }
        return KanbanDay(year: year, month: month, day: day)
    }

    private static func validateSourceRef(_ ref: String) -> Bool {
        if ref == "text" { return true }
        if ref.hasPrefix("image-") {
            let suffix = ref.dropFirst(6)
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
        return false
    }
}
