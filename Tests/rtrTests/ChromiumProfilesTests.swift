import Testing
import Foundation
@testable import rtr

@Suite("Chromium Local State parsing")
struct ChromiumProfilesTests {

    private func data(_ json: String) -> Data {
        json.data(using: .utf8)!
    }

    @Test func parsesProfilesInDeclaredOrder() {
        let json = """
        {
          "profile": {
            "profiles_order": ["Profile 2", "Default"],
            "info_cache": {
              "Default": { "name": "Personal" },
              "Profile 2": { "name": "Work" }
            }
          }
        }
        """
        let result = ChromiumProfiles.parse(localStateData: data(json))
        #expect(result.map(\.directory) == ["Profile 2", "Default"])
        #expect(result.map(\.name) == ["Work", "Personal"])
    }

    @Test func fallsBackToShortcutNameAndDirectory() {
        let json = """
        {
          "profile": {
            "info_cache": {
              "Profile 1": { "shortcut_name": "ShortcutOnly" },
              "Profile 2": { }
            }
          }
        }
        """
        let result = ChromiumProfiles.parse(localStateData: data(json))
        #expect(Set(result.map(\.directory)) == ["Profile 1", "Profile 2"])
        let byDir = Dictionary(uniqueKeysWithValues: result.map { ($0.directory, $0.name) })
        #expect(byDir["Profile 1"] == "ShortcutOnly")
        #expect(byDir["Profile 2"] == "Profile 2") // falls back to dir name
    }

    @Test func noOrderPutsDefaultFirstThenAlphabetical() {
        let json = """
        {
          "profile": {
            "info_cache": {
              "Profile 1": { "name": "zeta" },
              "Profile 2": { "name": "alpha" },
              "Default":   { "name": "main" }
            }
          }
        }
        """
        let result = ChromiumProfiles.parse(localStateData: data(json))
        #expect(result.map(\.directory) == ["Default", "Profile 2", "Profile 1"])
    }

    @Test func profilesNotInOrderAreAppendedAlphabetically() {
        let json = """
        {
          "profile": {
            "profiles_order": ["Default"],
            "info_cache": {
              "Default":   { "name": "main" },
              "Profile 1": { "name": "zeta" },
              "Profile 2": { "name": "alpha" }
            }
          }
        }
        """
        let result = ChromiumProfiles.parse(localStateData: data(json))
        #expect(result.map(\.directory) == ["Default", "Profile 2", "Profile 1"])
    }

    @Test func invalidJSONReturnsEmpty() {
        #expect(ChromiumProfiles.parse(localStateData: data("not json")).count == 0)
    }

    @Test func missingProfileBlockReturnsEmpty() {
        #expect(ChromiumProfiles.parse(localStateData: data("{}")).count == 0)
    }

    @Test func loadFromMissingFileURLReturnsEmpty() {
        let url = URL(fileURLWithPath: "/var/empty/does-not-exist/Local State")
        #expect(ChromiumProfiles.load(stateURL: url).count == 0)
    }
}
