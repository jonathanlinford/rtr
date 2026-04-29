import Foundation

struct Rule {
    enum Matcher {
        case domain(String)        // exact host or suffix match (e.g. "github.com" matches "foo.github.com")
        case substring(String)
        case regex(NSRegularExpression)
        case sourceApp(String)     // bundle ID equality
    }
    let matchers: [Matcher]        // AND semantics within a rule
    let browserID: String
}

final class Config {
    static let shared = Config()

    private(set) var rules: [Rule] = []
    private(set) var defaultBrowserID: String?

    let configDir: URL
    var configPath: URL { configDir.appendingPathComponent("config.json") }

    /// Default init: uses `~/.config/rtr`.
    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.configDir = home.appendingPathComponent(".config/rtr")
    }

    /// Test/DI init: point at any directory.
    init(configDir: URL) {
        self.configDir = configDir
    }

    func load() {
        writeDefaultIfMissing()
        guard let data = try? Data(contentsOf: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.rules = []
            self.defaultBrowserID = nil
            return
        }

        self.defaultBrowserID = json["default_browser"] as? String

        var parsed: [Rule] = []
        if let rawRules = json["rules"] as? [[String: Any]] {
            for raw in rawRules {
                guard let browserID = raw["browser"] as? String else { continue }
                var matchers: [Rule.Matcher] = []

                if let v = raw["domain"] as? String { matchers.append(.domain(v.lowercased())) }
                if let vs = raw["domain"] as? [String] { matchers.append(contentsOf: vs.map { .domain($0.lowercased()) }) }

                if let v = raw["substring"] as? String { matchers.append(.substring(v)) }
                if let vs = raw["substring"] as? [String] { matchers.append(contentsOf: vs.map { .substring($0) }) }

                if let v = raw["regex"] as? String, let re = try? NSRegularExpression(pattern: v) {
                    matchers.append(.regex(re))
                }
                if let vs = raw["regex"] as? [String] {
                    for p in vs {
                        if let re = try? NSRegularExpression(pattern: p) { matchers.append(.regex(re)) }
                    }
                }

                if let v = raw["source_app"] as? String { matchers.append(.sourceApp(v)) }
                if let vs = raw["source_app"] as? [String] { matchers.append(contentsOf: vs.map { .sourceApp($0) }) }

                guard !matchers.isEmpty else { continue }
                parsed.append(Rule(matchers: matchers, browserID: browserID))
            }
        }
        self.rules = parsed
    }

    func match(url: URL, sourceBundleID: String?) -> String? {
        let host = (url.host ?? "").lowercased()
        let full = url.absoluteString

        for rule in rules {
            var ok = true
            for m in rule.matchers {
                switch m {
                case .domain(let d):
                    if !(host == d || host.hasSuffix("." + d)) { ok = false }
                case .substring(let s):
                    if !full.contains(s) { ok = false }
                case .regex(let re):
                    let range = NSRange(full.startIndex..., in: full)
                    if re.firstMatch(in: full, range: range) == nil { ok = false }
                case .sourceApp(let b):
                    if sourceBundleID?.caseInsensitiveCompare(b) != .orderedSame { ok = false }
                }
                if !ok { break }
            }
            if ok { return rule.browserID }
        }
        return nil
    }

    enum MatcherKind: String { case domain, substring, regex, source_app }

    /// Append a rule and persist the config. Reloads in-memory rules on success.
    /// Returns false if the config file can't be parsed (user has bad JSON).
    @discardableResult
    func appendRule(matcher: MatcherKind, value: String, browserID: String) -> Bool {
        writeDefaultIfMissing()
        guard let data = try? Data(contentsOf: configPath),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        var rules = obj["rules"] as? [[String: Any]] ?? []
        let newRule: [String: Any] = [
            matcher.rawValue: value,
            "browser": browserID
        ]
        rules.append(newRule)
        obj["rules"] = rules

        guard let out = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        try? out.write(to: configPath, options: .atomic)
        load()
        return true
    }

    func writeDefaultIfMissing() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir.path) {
            try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: configPath.path) { return }

        let template = """
        {
          "_comment": "rtr config. Reload via menubar → Reload Config.",
          "default_browser": null,

          "_browser_ids": "Use the IDs shown in the picker tooltip, or one of: bundle ID (e.g. 'com.apple.Safari'), 'bundleID#ProfileDir' (e.g. 'com.google.Chrome#Default'), or friendly alias 'chrome:ProfileName'.",

          "rules": [
            {
              "_comment": "Examples — delete or edit. First match wins.",
              "domain": "example.invalid",
              "browser": "com.apple.Safari"
            }
          ]
        }
        """
        try? template.data(using: .utf8)?.write(to: configPath)
    }
}
