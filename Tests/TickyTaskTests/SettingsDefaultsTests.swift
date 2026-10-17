import Testing
import Foundation
@testable import TickyTask

/// Settings read in code must agree with `@AppStorage`, including values given as text
/// (launch arguments). On 2026-10-17, a Saturday, `-showWeekends YES` read as "hidden" in
/// carry-forward, which moved the UI tests' tasks for today to Monday.
@Suite("Settings defaults")
struct SettingsDefaultsTests {
    private func defaults() throws -> UserDefaults {
        let name = "SettingsDefaults-\(UUID())"
        let d = try #require(UserDefaults(suiteName: name))
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func missingSettingUsesTheFallback() throws {
        let d = try defaults()
        #expect(d.bool(forKey: "showWeekends", default: false) == false)
        #expect(d.bool(forKey: "autoCarryForward", default: true) == true)
        #expect(d.integer(forKey: "calendarColumns", default: 5) == 5)
    }

    @Test func storedValuesWin() throws {
        let d = try defaults()
        d.set(false, forKey: "autoCarryForward")
        d.set(true, forKey: "showWeekends")
        d.set(7, forKey: "calendarColumns")
        #expect(d.bool(forKey: "autoCarryForward", default: true) == false)
        #expect(d.bool(forKey: "showWeekends", default: false) == true)
        #expect(d.integer(forKey: "calendarColumns", default: 5) == 7)
    }

    @Test func textValuesReadLikeAppStorage() throws {
        let d = try defaults()
        d.set("YES", forKey: "showWeekends")
        d.set("NO", forKey: "weekStartsMonday")
        d.set("7", forKey: "calendarColumns")
        #expect(d.bool(forKey: "showWeekends", default: false) == true)
        #expect(d.bool(forKey: "weekStartsMonday", default: true) == false)
        #expect(d.integer(forKey: "calendarColumns", default: 5) == 7)
        let todayKey = "20261017"   // a Saturday
        let shown = d.bool(forKey: "showWeekends", default: false)
        #expect(BehaviorService.carryForwardTarget(todayKey: todayKey, showWeekends: shown) == todayKey,
                "weekends shown: today's tasks stay on Saturday")
    }
}
