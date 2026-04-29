import Testing
import Foundation
@testable import rtr

@Suite("Settings.profileDisplay persistence", .serialized)
struct SettingsTests {

    @Test func rawValuesAreStable() {
        // UserDefaults persists rawValue — renaming would silently invalidate
        // existing users' settings.
        #expect(ProfileDisplayMode.grouped.rawValue == "grouped")
        #expect(ProfileDisplayMode.flat.rawValue    == "flat")
    }

    @Test func allCasesHaveMenuLabels() {
        for mode in ProfileDisplayMode.allCases {
            #expect(!mode.menuLabel.isEmpty)
        }
    }

    @Test func unknownStoredValueFallsBackToGrouped() {
        let key = Settings.profileDisplayKey
        let prev = UserDefaults.standard.string(forKey: key)
        defer {
            if let prev { UserDefaults.standard.set(prev, forKey: key) }
            else        { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.set("not-a-mode", forKey: key)
        #expect(Settings.profileDisplay == .grouped)

        UserDefaults.standard.removeObject(forKey: key)
        #expect(Settings.profileDisplay == .grouped)
    }

    @Test func roundTripPersistsSelection() {
        let key = Settings.profileDisplayKey
        let prev = UserDefaults.standard.string(forKey: key)
        defer {
            if let prev { UserDefaults.standard.set(prev, forKey: key) }
            else        { UserDefaults.standard.removeObject(forKey: key) }
        }

        Settings.profileDisplay = .flat
        #expect(Settings.profileDisplay == .flat)
        Settings.profileDisplay = .grouped
        #expect(Settings.profileDisplay == .grouped)
    }
}
