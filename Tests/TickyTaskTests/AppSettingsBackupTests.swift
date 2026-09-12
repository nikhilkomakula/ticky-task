import Testing
import Foundation
@testable import TickyTask

@Suite("App settings backup")
struct AppSettingsBackupTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "ticky-settings-" + UUID().uuidString)!
    }

    @Test("Capture reflects set keys and omits unset ones")
    func captureReflectsState() {
        let d = suite()
        d.set("dark", forKey: "appTheme")
        d.set(3, forKey: "calendarColumns")
        d.set(true, forKey: "showWeekends")
        d.set(true, forKey: "autoDeleteCompletedEnabled")
        d.set(14, forKey: "autoDeleteCompletedDays")

        let dto = AppSettingsDTO.capture(from: d)

        #expect(dto.appTheme == "dark")
        #expect(dto.calendarColumns == 3)
        #expect(dto.showWeekends == true)
        #expect(dto.autoDeleteCompletedEnabled == true)
        #expect(dto.autoDeleteCompletedDays == 14)
        #expect(dto.weekStartsMonday == nil)   // never set → omitted from the backup
    }

    @Test("Apply reproduces the backup: writes present values, resets absent ones")
    func applyReproducesBackup() {
        let d = suite()
        d.set(false, forKey: "weekStartsMonday")   // an explicit value on the target
        d.set(true, forKey: "showWeekends")

        var dto = AppSettingsDTO()
        dto.appTheme = "light"
        dto.autoCheckUpdates = false
        dto.apply(to: d)

        #expect(d.string(forKey: "appTheme") == "light")
        #expect(d.object(forKey: "autoCheckUpdates") as? Bool == false)
        // weekStartsMonday wasn't in the backup → reset (removed) so the destination
        // reproduces the source's effective settings, not a stale local override.
        #expect(d.object(forKey: "weekStartsMonday") == nil)
        #expect(d.object(forKey: "showWeekends") == nil)
    }

    @Test("Settings survive a plaintext backup round-trip")
    func roundTripsThroughBackup() throws {
        var settings = AppSettingsDTO()
        settings.appTheme = "dark"
        settings.showWeekends = true
        settings.autoDeleteCompletedDays = 30
        settings.menuBarOnly = true
        let store = BackupStoreDTO(
            schemaVersion: 1, appVersion: "1.0",
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            data: BackupDataDTO(taskItems: [], subtasks: [], taskTags: [],
                                customLists: [], taskOccurrences: []),
            settings: settings
        )
        let service = BackupService()
        let decoded = try service.readFile(service.makeFile(store: store, passphrase: nil), passphrase: nil)
        #expect(decoded.settings?.appTheme == "dark")
        #expect(decoded.settings?.showWeekends == true)
        #expect(decoded.settings?.autoDeleteCompletedDays == 30)
        #expect(decoded.settings?.menuBarOnly == true)
    }
}
