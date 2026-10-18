import Testing
import Foundation
@testable import TickyTask

struct AvailabilityAssistantTests {
    @Test
    func contractValidatorAcceptsValidJSON() {
        let json = """
{
  "schemaVersion": 1,
  "entries": [
    {
      "sourceRef": "text",
      "personText": "Alice",
      "startDate": "2025-01-01",
      "endDate": "2025-01-03",
      "portion": "full",
      "kind": "pto",
      "dateText": "Jan 1-3",
      "evidence": "Alice: PTO Jan 1-3",
      "confidence": "high",
      "issues": []
    }
  ],
  "unresolved": [],
  "warnings": []
}
""".data(using: .utf8)!

        let result = AvailabilityContractValidator.validate(json)
        switch result {
        case .success(let validation):
            #expect(validation.entries.count == 1)
            #expect(validation.entries[0].personText == "Alice")
        case .failure:
            #expect(Bool(false), "Validation should succeed")
        }
    }

    @Test
    func contractValidatorRejectsWrongSchemaVersion() {
        let json = """
{
  "schemaVersion": 2,
  "entries": [],
  "unresolved": [],
  "warnings": []
}
""".data(using: .utf8)!

        let result = AvailabilityContractValidator.validate(json)
        switch result {
        case .success:
            #expect(Bool(false), "Should reject version 2")
        case .failure(let error):
            #expect(error.errorDescription?.contains("Schema version") ?? false)
        }
    }

    @Test
    func personMatcherFindsAliases() {
        let alice = KanbanPerson(name: "Alice Johnson")
        alice.aliases = ["A.J.", "Alice"]

        let result = AvailabilityPersonMatcher.match("A.J.", against: [alice])
        #expect(result.matched?.id == alice.id)
    }

    @Test
    func personMatcherReturnsNoneForDuplicates() {
        let alice1 = KanbanPerson(name: "Alice")
        let alice2 = KanbanPerson(name: "Alice")

        let result = AvailabilityPersonMatcher.match("Alice", against: [alice1, alice2])
        #expect(result.matched == nil)
    }
}
