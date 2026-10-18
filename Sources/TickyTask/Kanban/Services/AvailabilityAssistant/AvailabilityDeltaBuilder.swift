import Foundation

enum AvailabilityDeltaBuilder {
    /// Build a delta from selected proposals and user's alias choices.
    static func build(from proposals: [AvailabilityProposal],
                      existingPeople: [KanbanPerson],
                      existingBoards: [KanbanProject]) -> ApplyableAvailabilityDelta {
        var timeOffDelta: [KanbanAvailabilityDelta.TimeOff] = []
        var aliasDelta: [KanbanAvailabilityDelta.Aliases] = []
        var affectedPeople = Set<UUID>()
        var affectedBoards = Set<UUID>()

        for proposal in proposals {
            guard proposal.isSelected else { continue }

            let entry = proposal.entry
            guard let person = proposal.resolvedPerson else { continue }

            affectedPeople.insert(person.id)

            // Find boards this person is on
            for board in existingBoards {
                if board.resources.contains(where: { $0.person?.id == person.id }) {
                    affectedBoards.insert(board.id)
                }
            }

            let newDTO = KanbanTimeOffDTO(
                id: UUID(),
                personId: person.id,
                startDay: entry.startDate.key,
                endDay: entry.endDate.key,
                portion: entry.portion,
                kind: entry.kind,
                note: nil,  // Imported notes are empty per design
                origin: .assistant,
                createdAt: Date(),
                updatedAt: Date()
            )

            timeOffDelta.append(.init(id: newDTO.id, before: nil, after: newDTO))

            // Remember alias if user selected it
            if proposal.rememberAlias && !entry.personText.isEmpty {
                let oldAliases = person.aliases ?? []
                if !oldAliases.contains(entry.personText) {
                    var newAliases = oldAliases
                    newAliases.append(entry.personText)
                    aliasDelta.append(.init(personID: person.id, before: oldAliases.isEmpty ? nil : oldAliases,
                                           after: newAliases))
                }
            }
        }

        let delta = KanbanAvailabilityDelta(timeOff: timeOffDelta, aliases: aliasDelta)

        let affectedPeopleList = existingPeople.filter { affectedPeople.contains($0.id) }
        let summary = buildSummary(timeOffCount: timeOffDelta.count, personCount: affectedPeople.count,
                                   boardCount: affectedBoards.count)

        return .init(delta: delta, summary: summary, affectedPeople: affectedPeopleList, affectedBoards: affectedBoards)
    }

    private static func buildSummary(timeOffCount: Int, personCount: Int, boardCount: Int) -> String {
        let timeOffStr = timeOffCount == 1 ? "1 entry" : "\(timeOffCount) entries"
        let personStr = personCount == 1 ? "1 person" : "\(personCount) people"
        let boardStr = boardCount == 1 ? "1 board" : "\(boardCount) boards"
        return "Applies \(timeOffStr) to \(personStr) across \(boardStr)"
    }
}
