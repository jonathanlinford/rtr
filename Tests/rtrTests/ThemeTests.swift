import Testing
import AppKit
@testable import rtr

@Suite("Appearance mode persistence & resolution")
struct ThemeTests {

    @Test func systemModeMapsToNilNSAppearance() {
        #expect(AppearanceMode.system.nsAppearance == nil)
    }

    @Test func lightModeMapsToAqua() {
        #expect(AppearanceMode.light.nsAppearance?.name == .aqua)
    }

    @Test func darkModeMapsToDarkAqua() {
        #expect(AppearanceMode.dark.nsAppearance?.name == .darkAqua)
    }

    @Test func allCasesAreCovered() {
        // If a future case is added, it must have a menuLabel + nsAppearance answer.
        for mode in AppearanceMode.allCases {
            #expect(!mode.menuLabel.isEmpty)
            _ = mode.nsAppearance // doesn't crash
        }
    }

    @Test func rawValuesAreStable() {
        // UserDefaults persists rawValue — renaming would silently invalidate
        // existing users' settings.
        #expect(AppearanceMode.system.rawValue == "system")
        #expect(AppearanceMode.light.rawValue  == "light")
        #expect(AppearanceMode.dark.rawValue   == "dark")
    }

    @Test func unknownStoredValueFallsBackToSystem() {
        let key = Theme.storageKey
        let prev = UserDefaults.standard.string(forKey: key)
        defer {
            if let prev { UserDefaults.standard.set(prev, forKey: key) }
            else        { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.set("not-a-real-mode", forKey: key)
        #expect(Theme.mode == .system)

        UserDefaults.standard.removeObject(forKey: key)
        #expect(Theme.mode == .system)
    }
}
