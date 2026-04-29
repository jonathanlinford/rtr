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

    @Test func parsesGaiaPictureFileName() {
        let json = """
        {
          "profile": {
            "info_cache": {
              "Default": {
                "name": "Personal",
                "gaia_picture_file_name": "Google Profile Picture.png"
              },
              "Profile 2": { "name": "Work" }
            }
          }
        }
        """
        let result = ChromiumProfiles.parse(localStateData: data(json))
        let byDir = Dictionary(uniqueKeysWithValues: result.map { ($0.directory, $0) })
        #expect(byDir["Default"]?.avatarFileName == "Google Profile Picture.png")
        #expect(byDir["Profile 2"]?.avatarFileName == nil)
        // parse() never resolves URLs (it doesn't know paths).
        #expect(byDir["Default"]?.avatarURL == nil)
    }

    @Test func loadResolvesAvatarURLOnlyWhenFileExists() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rtr-chromium-\(UUID().uuidString)", isDirectory: true)
        let support = tmp.appendingPathComponent("Chromium")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Profile A has an avatar file on disk; Profile B claims one but the file is missing.
        let profileADir = support.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profileADir, withIntermediateDirectories: true)
        let avatarPath = profileADir.appendingPathComponent("Google Profile Picture.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: avatarPath) // PNG-ish bytes; existence is what matters

        let stateURL = support.appendingPathComponent("Local State")
        try """
        {
          "profile": {
            "info_cache": {
              "Default":   { "name": "Personal", "gaia_picture_file_name": "Google Profile Picture.png" },
              "Profile 2": { "name": "Work",     "gaia_picture_file_name": "Google Profile Picture.png" }
            }
          }
        }
        """.write(to: stateURL, atomically: true, encoding: .utf8)

        let result = ChromiumProfiles.load(stateURL: stateURL, supportRoot: support)
        let byDir = Dictionary(uniqueKeysWithValues: result.map { ($0.directory, $0) })
        #expect(byDir["Default"]?.avatarURL == avatarPath)
        // File doesn't exist for Profile 2 → URL not attached.
        #expect(byDir["Profile 2"]?.avatarURL == nil)
        #expect(byDir["Profile 2"]?.avatarFileName == "Google Profile Picture.png")
    }
}
