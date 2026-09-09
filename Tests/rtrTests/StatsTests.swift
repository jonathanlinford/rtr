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

    // MARK: - splitBrowserName

    @Test func splitsBrowserNameIntoBaseAndProfile() {
        #expect(splitBrowserName("Google Chrome — Work").base == "Google Chrome")
        #expect(splitBrowserName("Google Chrome — Work").profile == "Work")
        #expect(splitBrowserName("Safari").base == "Safari")
        #expect(splitBrowserName("Safari").profile == nil)
    }

    // MARK: - bundle / profile rollups

    @Test func snapshotRollsUpBundlesAndProfiles() {
        let now = Date().timeIntervalSince1970
        let entries = [
            entry(t: now, browserID: "com.google.Chrome#Default", name: "Google Chrome — Work"),
            entry(t: now, browserID: "com.google.Chrome#Profile 1", name: "Google Chrome — Work"),
            entry(t: now, browserID: "com.google.Chrome#Profile 2", name: "Google Chrome — Personal"),
            entry(t: now, browserID: "com.apple.Safari", name: "Safari"),
        ]
        let snap = StatsSnapshot.from(entries)

        // Bundle: Chrome rolled up across profiles = 3, Safari = 1.
        let bundle = Dictionary(uniqueKeysWithValues: snap.byBundle.map { ($0.key, $0.count) })
        #expect(bundle["Google Chrome"] == 3)
        #expect(bundle["Safari"] == 1)

        // Profiles: Work 2, Personal 1. Safari (no profile) absent.
        let profile = Dictionary(uniqueKeysWithValues: snap.byProfile.map { ($0.key, $0.count) })
        #expect(profile["Work"] == 2)
        #expect(profile["Personal"] == 1)
        #expect(profile["Safari"] == nil)
    }

    // MARK: - time of day

    @Test func snapshotBucketsByHourAndWeekday() {
        // 2024-01-01 is a Monday (Calendar weekday 2 → index 1).
        let entries = [
            timedEntry(2024, 1, 1, 9),   // Mon 09:00
            timedEntry(2024, 1, 1, 9),   // Mon 09:00
            timedEntry(2024, 1, 1, 14),  // Mon 14:00
            timedEntry(2024, 1, 6, 22),  // Sat 22:00
        ]
        let snap = StatsSnapshot.from(entries)

        #expect(snap.byHour[9] == 2)
        #expect(snap.byHour[14] == 1)
        #expect(snap.byHour[22] == 1)
        #expect(snap.busiestHour?.hour == 9)
        #expect(snap.busiestHour?.count == 2)

        #expect(snap.byWeekday[1] == 3)   // Monday
        #expect(snap.byWeekday[6] == 1)   // Saturday
        #expect(snap.weekdayCount == 3)
        #expect(snap.weekendCount == 1)

        #expect(snap.heatmap[1][9] == 2)  // Mon × 09:00
        #expect(snap.heatmap[6][22] == 1) // Sat × 22:00
    }

    // MARK: - streaks & fun stats

    @Test func snapshotComputesStreaksAndBusiestDay() {
        let entries = [
            timedEntry(2024, 3, 1, 10),
            timedEntry(2024, 3, 2, 10),
            timedEntry(2024, 3, 3, 10),
            timedEntry(2024, 3, 3, 11),   // busiest day (2 links)
            // gap on the 4th
            timedEntry(2024, 3, 5, 10),
            timedEntry(2024, 3, 6, 10),
        ]
        let snap = StatsSnapshot.from(entries)

        #expect(snap.activeDays == 5)
        #expect(snap.longestStreak == 3)   // Mar 1–3
        #expect(snap.currentStreak == 2)   // Mar 5–6

        let cal = Calendar.current
        let busiest = snap.busiestDay
        #expect(busiest?.count == 2)
        #expect(busiest.map { cal.component(.day, from: $0.day) } == 3)

        #expect(abs(snap.avgPerActiveDay - 6.0 / 5.0) < 0.0001)
    }

    @Test func snapshotFindsFavoriteCombo() {
        let now = Date().timeIntervalSince1970
        let entries = [
            StatEntry(t: now, url: "https://github.com/a", host: "github.com",
                      browserID: "id", browserName: "Chrome — Work", sourceApp: nil, ruleMatched: false),
            StatEntry(t: now, url: "https://github.com/b", host: "github.com",
                      browserID: "id", browserName: "Chrome — Work", sourceApp: nil, ruleMatched: false),
            StatEntry(t: now, url: "https://news.com", host: "news.com",
                      browserID: "id2", browserName: "Safari", sourceApp: nil, ruleMatched: false),
        ]
        let snap = StatsSnapshot.from(entries)
        #expect(snap.favoriteCombo?.browser == "Chrome — Work")
        #expect(snap.favoriteCombo?.host == "github.com")
        #expect(snap.favoriteCombo?.count == 2)
    }

    // MARK: - helpers

    private func timedEntry(_ y: Int, _ mo: Int, _ d: Int, _ h: Int) -> StatEntry {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = 0
        let t = Calendar.current.date(from: c)!.timeIntervalSince1970
        return StatEntry(t: t, url: "https://x.com", host: "x.com",
                         browserID: "id", browserName: "Chrome", sourceApp: nil, ruleMatched: false)
    }

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

    private func entry(t: TimeInterval, browserID: String, name: String) -> StatEntry {
        StatEntry(t: t, url: "u", host: "h",
                  browserID: browserID, browserName: name,
                  sourceApp: nil, ruleMatched: false)
    }
}
