import Testing
import Foundation
@testable import rtr

@Suite("Config rule parsing & matching")
final class ConfigTests {
    let tmpDir: URL

    init() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rtr-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeConfig(_ json: String) throws {
        let path = tmpDir.appendingPathComponent("config.json")
        try json.write(to: path, atomically: true, encoding: .utf8)
    }

    private func makeConfig() -> Config {
        Config(configDir: tmpDir)
    }

    // MARK: - Domain matcher

    @Test func domainExactMatch() throws {
        try writeConfig("""
        { "rules": [ { "domain": "github.com", "browser": "com.google.Chrome" } ] }
        """)
        let cfg = makeConfig()
        cfg.load()
        #expect(cfg.match(url: URL(string: "https://github.com/foo")!, sourceBundleID: nil)
                == "com.google.Chrome")
    }

    @Test func domainSuffixMatch() throws {
        try writeConfig("""
        { "rules": [ { "domain": "github.com", "browser": "chrome" } ] }
        """)
        let cfg = makeConfig()
        cfg.load()
        #expect(cfg.match(url: URL(string: "https://gist.github.com/x")!, sourceBundleID: nil)
                == "chrome")
    }

    @Test func domainSiblingDoesNotMatch() throws {
        try writeConfig("""
        { "rules": [ { "domain": "github.com", "browser": "chrome" } ] }
        """)
        let cfg = makeConfig()
        cfg.load()
        // "foogithub.com" should not match — only "github.com" or "*.github.com".
        #expect(cfg.match(url: URL(string: "https://foogithub.com/")!, sourceBundleID: nil) == nil)
    }

    @Test func domainArrayAddsMatchersWithAndSemantics() throws {
        try writeConfig("""
        { "rules": [ { "domain": ["a.com", "b.com"], "browser": "x" } ] }
        """)
        let cfg = makeConfig()
        cfg.load()
        // domain-as-array adds two matchers AND'd together → no host satisfies both.
        // This documents current behavior.
        #expect(cfg.match(url: URL(string: "https://a.com/")!, sourceBundleID: nil) == nil)
    }

    // MARK: - Substring matcher

    @Test func substringMatch() throws {
        try writeConfig("""
        { "rules": [ { "substring": "/admin/", "browser": "safari" } ] }
        """)
        let cfg = makeConfig()
        cfg.load()
        #expect(cfg.match(url: URL(string: "https://x.com/admin/users")!, sourceBundleID: nil)
                == "safari")
        #expect(cfg.match(url: URL(string: "https://x.com/users")!, sourceBundleID: nil) == nil)
    }

    // MARK: - Regex matcher

    @Test func regexMatch() throws {
        try writeConfig(#"""
        { "rules": [ { "regex": "^https?://(localhost|127\\.0\\.0\\.1)", "browser": "brave" } ] }
        """#)
        let cfg = makeConfig()
        cfg.load()
        #expect(cfg.match(url: URL(string: "http://localhost:3000")!, sourceBundleID: nil) == "brave")
        #expect(cfg.match(url: URL(string: "https://127.0.0.1/x")!, sourceBundleID: nil) == "brave")
        #expect(cfg.match(url: URL(string: "https://example.com")!, sourceBundleID: nil) == nil)
    }

    // MARK: - Source app matcher

    @Test func sourceAppMatchIsCaseInsensitive() throws {
        try writeConfig("""
        { "rules": [ { "source_app": "com.tinyspeck.slackmacgap", "browser": "arc" } ] }
        """)
        let cfg = makeConfig()
        cfg.load()
        #expect(cfg.match(url: URL(string: "https://x.com")!,
                          sourceBundleID: "COM.TINYSPECK.SLACKMACGAP") == "arc")
        #expect(cfg.match(url: URL(string: "https://x.com")!, sourceBundleID: "com.other.app") == nil)
    }

    // MARK: - AND semantics within a rule

    @Test func andSemanticsRequireBothToMatch() throws {
        try writeConfig("""
        {
          "rules": [
            { "domain": "github.com", "source_app": "com.tinyspeck.slackmacgap", "browser": "arc" }
          ]
        }
        """)
        let cfg = makeConfig()
        cfg.load()
        #expect(cfg.match(url: URL(string: "https://github.com")!,
                          sourceBundleID: "com.tinyspeck.slackmacgap") == "arc")
        // Domain matches but source app doesn't → no match.
        #expect(cfg.match(url: URL(string: "https://github.com")!,
                          sourceBundleID: "com.apple.Mail") == nil)
        // Source matches but domain doesn't → no match.
        #expect(cfg.match(url: URL(string: "https://example.com")!,
                          sourceBundleID: "com.tinyspeck.slackmacgap") == nil)
    }

    // MARK: - First match wins

    @Test func firstRuleWins() throws {
        try writeConfig("""
        {
          "rules": [
            { "domain": "github.com", "browser": "first" },
            { "domain": "github.com", "browser": "second" }
          ]
        }
        """)
        let cfg = makeConfig()
        cfg.load()
        #expect(cfg.match(url: URL(string: "https://github.com")!, sourceBundleID: nil) == "first")
    }

    // MARK: - Default browser

    @Test func defaultBrowserParsed() throws {
        try writeConfig("""
        { "default_browser": "com.apple.Safari", "rules": [] }
        """)
        let cfg = makeConfig()
        cfg.load()
        #expect(cfg.defaultBrowserID == "com.apple.Safari")
    }

    // MARK: - writeDefaultIfMissing

    @Test func writeDefaultIfMissingCreatesFile() {
        let cfg = makeConfig()
        #expect(!FileManager.default.fileExists(atPath: cfg.configPath.path))
        cfg.writeDefaultIfMissing()
        #expect(FileManager.default.fileExists(atPath: cfg.configPath.path))
    }

    @Test func writeDefaultIfMissingDoesNotOverwrite() throws {
        let cfg = makeConfig()
        try writeConfig("""
        { "default_browser": "x", "rules": [] }
        """)
        cfg.writeDefaultIfMissing()
        let contents = try String(contentsOf: cfg.configPath)
        #expect(contents.contains("\"default_browser\": \"x\""))
    }

    // MARK: - Malformed config doesn't crash

    @Test func malformedConfigYieldsEmptyRules() throws {
        try writeConfig("not valid json {{{")
        let cfg = makeConfig()
        cfg.load()
        #expect(cfg.rules.count == 0)
        #expect(cfg.defaultBrowserID == nil)
    }

    @Test func ruleWithoutBrowserIsSkipped() throws {
        try writeConfig("""
        { "rules": [ { "domain": "x.com" } ] }
        """)
        let cfg = makeConfig()
        cfg.load()
        #expect(cfg.rules.count == 0)
    }

    // MARK: - appendRule round-trips

    @Test func appendRulePersistsAndReloads() {
        let cfg = makeConfig()
        cfg.writeDefaultIfMissing()
        cfg.load()
        let added = cfg.appendRule(matcher: .domain, value: "added.example", browserID: "safari")
        #expect(added)

        // Fresh instance pointed at the same dir should see the new rule.
        let other = Config(configDir: tmpDir)
        other.load()
        #expect(other.match(url: URL(string: "https://added.example")!, sourceBundleID: nil)
                == "safari")
    }
}
