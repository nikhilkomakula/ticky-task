import Foundation
@testable import TickyTask

extension RecurrenceRule {
    /// Test convenience: the same rule with `end` given after `startDate`.
    init(frequency: RecurrenceFrequency, interval: Int = 1, weekdays: Set<Int> = [], monthDays: [Int] = [],
         startDate: Date, end: RecurrenceEnd) {
        self.init(frequency: frequency, interval: interval, weekdays: weekdays, monthDays: monthDays,
                  end: end, startDate: startDate)
    }
}
