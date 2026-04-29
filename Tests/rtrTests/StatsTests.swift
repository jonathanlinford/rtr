import Testing
import Foundation
@testable import rtr

@Suite("Stats aggregation & ordering")
struct StatsTests {

    // MARK: - StatsSnapshot.from

    @Test func snapshotFromEmpty() {
        let snap = StatsSnapshot.from([])
        #expect(snap.total == 0)
        #expect(snap.ruleMatchedCount == 0)
        #expect(snap.last24hTotal == 0)
        #expect(snap.last7DaysTotal == 0)
        #expect(snap.sinceStart == nil)
        #expect(snap.byBrowser.isEmpty)
    }

    @Test func snapshotAggregates() {
        let now = Date().timeIntervalSince1970
        let day: TimeInterval = 86400
        let entries = [
            StatEntry(t: now,           url: "https://a.com",  host: "a.com",
                      browserID: "com.apple.Safari", browserName: "Safari",
                      sourceApp: "com.apple.Mail", ruleMatched: true),
            StatEntry(t: now - day / 2, url: "https://a.com",  host: "a.com",
                      browserID: "com.apple.Safari", browserName: "Safari",
                      sourceApp: "com.apple.Mail", ruleMatched: false),
            StatEntry(t: now - 3 * day, url: "https://b.com",  host: "b.com",
                      browserID: "com.google.Chrome", browserName: "Chrome",
                      sourceApp: nil, ruleMatched: false),
            StatEntry(t: now - 30 * day, url: "https://c.com", host: "c.com",
                      browserID: "com.google.Chrome", browserName: "Chrome",
                      sourceApp: "", ruleMatched: false),
        ]

        let snap = StatsSnapshot.from(entries)
        #expect(snap.total == 4)
        #expect(snap.ruleMatchedCount == 1)
        #expect(snap.last24hTotal == 2)
        #expect(snap.last7DaysTotal == 3)
        #expect(snap.sinceStart != nil)

        // Browsers: Chrome 2, Safari 2 — tied counts sort alphabetically by key.
        #expect(snap.byBrowser.first?.key == "Chrome")
        #expect(snap.byBrowser.first?.count == 2)

        // Domains: a.com 2, b.com 1, c.com 1.
        #expect(snap.byDomain.first?.key == "a.com")
        #expect(snap.byDomain.first?.count == 2)

        // Empty/nil source apps must not appear in the source-app bucket.
        let sourceKeys = Set(snap.bySourceApp.map(\.key))
        #expect(sourceKeys == ["com.apple.Mail"])
    }

    @Test func snapshotTiebreakIsAlphabetical() {
        let now = Date().timeIntervalSince1970
        let entries = [
            StatEntry(t: now, url: "u", host: "h", browserID: "id1", browserName: "Zeta",
                      sourceApp: nil, ruleMatched: false),
            StatEntry(t: now, url: "u", host: "h", browserID: "id1", browserName: "Alpha",
                      sourceApp: nil, ruleMatched: false),
        ]
        let snap = StatsSnapshot.from(entries)
        #expect(snap.byBrowser.map(\.key) == ["Alpha", "Zeta"])
    }

    // MARK: - bundleID(fromBrowserID:)

    @Test func bundleIDExtraction() {
        #expect(Stats.bundleID(fromBrowserID: "com.apple.Safari") == "com.apple.Safari")
        #expect(Stats.bundleID(fromBrowserID: "com.google.Chrome#Default") == "com.google.Chrome")
        #expect(Stats.bundleID(fromBrowserID: "com.google.Chrome#Profile 2") == "com.google.Chrome")
    }

    // MARK: - sortedGroups

    private func makeGroup(bundleID: String, name: String) -> BrowserGroup {
        let url = URL(fileURLWithPath: "/Applications/\(name).app")
        let browser = Browser(id: bundleID,
                              displayName: name,
                              bundleID: bundleID,
                              appURL: url,
                              kind: .simple)
        return BrowserGroup(displayName: name, bundleID: bundleID, appURL: url, browsers: [browser])
    }

    @Test func sortedGroupsEmptyHistoryPushesChromeToTop() {
        let stats = Stats(configDir: tempDir())
        let groups = [
            makeGroup(bundleID: "com.apple.Safari", name: "Safari"),
            makeGroup(bundleID: "org.mozilla.firefox", name: "Firefox"),
            makeGroup(bundleID: "com.google.Chrome", name: "Chrome"),
        ]
        let sorted = stats.sortedGroups(groups)
        #expect(sorted.map(\.bundleID).first == "com.google.Chrome")
    }

    @Test func sortedGroupsLastUsedFirstThenByCount() {
        let stats = Stats(configDir: tempDir())
        let now = Date().timeIntervalSince1970

        // Seed: Firefox last-used; Safari has the highest count among the rest.
        stats.seedAggregates(from: [
            entry(t: now - 100, browserID: "com.apple.Safari"),
            entry(t: now - 90,  browserID: "com.apple.Safari"),
            entry(t: now - 80,  browserID: "com.apple.Safari"),
            entry(t: now - 70,  browserID: "com.google.Chrome"),
            entry(t: now - 60,  browserID: "com.google.Chrome"),
            entry(t: now - 10,  browserID: "org.mozilla.firefox"),
        ])

        let groups = [
            makeGroup(bundleID: "com.apple.Safari",     name: "Safari"),
            makeGroup(bundleID: "org.mozilla.firefox",  name: "Firefox"),
            makeGroup(bundleID: "com.google.Chrome",    name: "Chrome"),
        ]
        let sorted = stats.sortedGroups(groups).map(\.bundleID)
        #expect(sorted == ["org.mozilla.firefox", "com.apple.Safari", "com.google.Chrome"])
    }

    @Test func lastBrowserIDReturnsMostRecentForBundle() {
        let stats = Stats(configDir: tempDir())
        let now = Date().timeIntervalSince1970
        stats.seedAggregates(from: [
            entry(t: now - 100, browserID: "com.google.Chrome#Default"),
            entry(t: now - 50,  browserID: "com.google.Chrome#Profile 1"),
            entry(t: now - 10,  browserID: "com.apple.Safari"),
        ])
        #expect(stats.lastBrowserID(for: "com.google.Chrome") == "com.google.Chrome#Profile 1")
        #expect(stats.lastBrowserID(for: "com.apple.Safari") == "com.apple.Safari")
        #expect(stats.lastBrowserID(for: "org.mozilla.firefox") == nil)
    }

    // MARK: - record + loadAll round-trip

    @Test func recordAppendsJSONLLine() {
        let dir = tempDir()
        let stats = Stats(configDir: dir)
        stats.start()

        let url = URL(string: "https://example.com/x")!
        let browser = Browser(id: "com.apple.Safari",
                              displayName: "Safari",
                              bundleID: "com.apple.Safari",
                              appURL: URL(fileURLWithPath: "/Applications/Safari.app"),
                              kind: .simple)
        stats.record(url: url, browser: browser, sourceBundleID: "com.apple.Mail", matchedRule: true)

        // The write happens on a serial utility queue. Poll briefly.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let data = try? Data(contentsOf: stats.path), !data.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let entries = stats.loadAll()
        #expect(entries.count == 1)
        #expect(entries.first?.browserID == "com.apple.Safari")
        #expect(entries.first?.host == "example.com")
        #expect(entries.first?.ruleMatched == true)
        // (in-memory aggregates after record() are covered by sortedGroups/lastBrowserID tests
        // above using seedAggregates — testing that here would race with start()'s async warmup.)
    }

    // MARK: - helpers

    private func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rtr-stats-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(t: TimeInterval, browserID: String) -> StatEntry {
        StatEntry(t: t, url: "u", host: "h",
                  browserID: browserID, browserName: browserID,
                  sourceApp: nil, ruleMatched: false)
    }
}
