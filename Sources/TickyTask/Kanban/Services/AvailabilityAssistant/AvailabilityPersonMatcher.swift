import Foundation

enum AvailabilityPersonMatcher {
    /// Match a person text against the available people.
    static func match(_ personText: String, against people: [KanbanPerson]) -> (matched: KanbanPerson?, suggestions: [KanbanPerson]) {
        let normalized = normalizeForMatching(personText)

        // 1. Try remembered alias (case- and diacritic-insensitive)
        if let person = people.first(where: { person in
            (person.aliases ?? []).contains { alias in
                normalizeForMatching(alias) == normalized
            }
        }) {
            return (person, [])
        }

        // 2. Try unique normalized full name
        let nameMatches = people.filter { person in
            normalizeForMatching(person.name) == normalized
        }
        if nameMatches.count == 1 {
            return (nameMatches[0], [])
        }

        // 3. Collect suggestions: initials and fuzzy matches
        var suggestions: [KanbanPerson] = []

        // Initials
        if let initialsMatch = people.first(where: { person in
            person.initials == personText.uppercased()
        }) {
            suggestions.append(initialsMatch)
        }

        // Fuzzy: people whose normalized name contains all words from personText
        let textWords = normalized.split(separator: " ").map(String.init)
        for person in people {
            guard !suggestions.contains(where: { $0.id == person.id }) else { continue }
            let nameWords = normalizeForMatching(person.name).split(separator: " ").map(String.init)
            if textWords.allSatisfy({ word in nameWords.contains { $0.contains(word) } }) {
                suggestions.append(person)
            }
        }

        return (nil, suggestions)
    }

    private static func normalizeForMatching(_ text: String) -> String {
        // Lowercase and remove punctuation for simple matching
        let lowercased = text.lowercased()
        let noPunctuation = lowercased.components(separatedBy: .punctuationCharacters).joined()
        return noPunctuation.trimmingCharacters(in: .whitespaces)
    }
}
