import Foundation

enum AvailabilityProposalClassifier {
    /// Classify a validated entry as a proposal against existing time off.
    static func classify(entry: ValidatedExtractionEntry,
                        matchedPerson: KanbanPerson?,
                        against existing: [KanbanTimeOff]) -> AvailabilityProposal.Classification {
        guard let person = matchedPerson else {
            return .needsReview(reason: "Person could not be resolved")
        }

        // Check if the entry itself has issues that need review
        if !entry.issues.isEmpty {
            return .needsReview(reason: entry.issues.joined(separator: "; "))
        }

        // Get this person's time off
        let personTimeOff = person.timeOff ?? []

        // Check for identical match
        for existing in personTimeOff {
            if isIdentical(entry: entry, timeOff: existing) {
                return .alreadyRecorded(id: existing.id)
            }
        }

        // Check for overlaps and collect what exists
        let overlappingEntries = personTimeOff.filter { timeOff in
            hasOverlap(entry: entry, timeOff: timeOff)
        }

        if !overlappingEntries.isEmpty {
            // Generate preview: split existing entries to not include the proposal's range
            let preview = previewAfterApplying(proposal: entry, toExisting: overlappingEntries)
            return .overlapsExisting(existing: overlappingEntries, preview: preview)
        }

        // No overlap
        return .new
    }

    private static func isIdentical(entry: ValidatedExtractionEntry, timeOff: KanbanTimeOff) -> Bool {
        let entryStart = entry.startDate.key
        let entryEnd = entry.endDate.key
        return timeOff.startDay == entryStart &&
               timeOff.endDay == entryEnd &&
               timeOff.portion == entry.portion &&
               timeOff.kind == entry.kind
    }

    private static func hasOverlap(entry: ValidatedExtractionEntry, timeOff: KanbanTimeOff) -> Bool {
        guard let existingStart = KanbanDay(key: timeOff.startDay),
              let existingEnd = KanbanDay(key: timeOff.endDay) else {
            return false
        }

        // Date ranges overlap if start <= other.end && end >= other.start
        guard entry.startDate <= existingEnd, entry.endDate >= existingStart else {
            return false
        }

        // Same date: check if portions overlap
        if entry.startDate == existingStart && entry.endDate == existingEnd {
            return overlappingPortions(entry.portion, timeOff.portion)
        }

        // Overlapping date ranges: always overlapping (can't check portions across ranges)
        return true
    }

    private static func overlappingPortions(_ a: KanbanTimeOffPortion, _ b: KanbanTimeOffPortion) -> Bool {
        // full overlaps with anything
        if a == .full || b == .full { return true }
        // same half day
        return a == b
    }

    /// Generate the preview of existing entries after applying this proposal.
    /// This splits entries so that the proposal's dates/portions are removed and the rest survives.
    private static func previewAfterApplying(proposal: ValidatedExtractionEntry,
                                             toExisting existing: [KanbanTimeOff]) -> [KanbanTimeOff] {
        var result: [KanbanTimeOff] = []

        for entry in existing {
            guard let start = KanbanDay(key: entry.startDay),
                  let end = KanbanDay(key: entry.endDay) else {
                result.append(entry)
                continue
            }

            // If the proposal doesn't actually overlap this entry on the calendar, keep as-is
            guard proposal.startDate <= end, proposal.endDate >= start else {
                result.append(entry)
                continue
            }

            // Split: keep days before proposal, after proposal, and portions not removed
            let proposalStart = proposal.startDate
            let proposalEnd = proposal.endDate

            // Before the proposal
            if start < proposalStart {
                let beforeEnd = proposalStart.adding(days: -1)
                let origin = KanbanTimeOffOrigin(rawValue: entry.originRaw) ?? .manual
                let before = KanbanTimeOff(id: entry.id, startDay: start.key, endDay: beforeEnd.key,
                                          portion: entry.portion, kind: entry.kind, origin: origin)
                before.note = entry.note
                result.append(before)
            }

            // After the proposal
            if end > proposalEnd {
                let afterStart = proposalEnd.adding(days: 1)
                let origin = KanbanTimeOffOrigin(rawValue: entry.originRaw) ?? .manual
                let after = KanbanTimeOff(id: UUID(), startDay: afterStart.key, endDay: end.key,
                                         portion: entry.portion, kind: entry.kind, origin: origin)
                after.note = entry.note
                result.append(after)
            }

            // Same date but different portion: keep non-overlapping portion
            if start == proposalStart && end == proposalEnd {
                if entry.portion == .full && proposal.portion != .full {
                    let remaining = proposal.portion == .am ? KanbanTimeOffPortion.pm : .am
                    let origin = KanbanTimeOffOrigin(rawValue: entry.originRaw) ?? .manual
                    let split = KanbanTimeOff(id: UUID(), startDay: start.key, endDay: start.key,
                                             portion: remaining, kind: entry.kind, origin: origin)
                    split.note = entry.note
                    result.append(split)
                } else if entry.portion != .full {
                    // Partial entry on same day: if it doesn't overlap, keep it
                    if !overlappingPortions(entry.portion, proposal.portion) {
                        result.append(entry)
                    }
                }
            }
        }

        return result
    }
}
