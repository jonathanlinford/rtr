import Foundation

struct StatEntry: Codable {
    let t: TimeInterval     // unix timestamp
    let url: String
    let host: String?
    let browserID: String
    let browserName: String
    let sourceApp: String?
    let ruleMatched: Bool
}

/// Time window for filtering stats. Drives the range switcher in the Stats window.
enum StatsRange: String, CaseIterable {
    case day, week, month, all

    var label: String {
        switch self {
        case .day:   return "24h"
        case .week:  return "7d"
        case .month: return "30d"
        case .all:   return "All"
        }
    }

    /// Seconds of look-back from "now"; `nil` means all time.
    var window: TimeInterval? {
        switch self {
        case .day:   return 24 * 3600
        case .week:  return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        case .all:   return nil
        }
    }

    func filter(_ entries: [StatEntry], now: TimeInterval) -> [StatEntry] {
        guard let w = window else { return entries }
        return entries.filter { now - $0.t <= w }
    }
}

/// Chromium browser display names are formatted "<App> — <Profile>" (see BrowserCatalog).
/// Split a recorded browserName into its base app and optional profile.
func splitBrowserName(_ name: String) -> (base: String, profile: String?) {
    if let r = name.range(of: " — ") {
        return (String(name[..<r.lowerBound]), String(name[r.upperBound...]))
    }
    return (name, nil)
}

final class Stats {
    static let shared = Stats()

    /// Posted on the main queue after each recorded click, so UI (menubar badge,
    /// open Stats window) can refresh live.
    static let didRecordNotification = Notification.Name("rtr.stats.didRecord")

    private let queue = DispatchQueue(label: "com.jonny.rtr.stats", qos: .utility)
    private var fileHandle: FileHandle?
    private let configDir: () -> URL

    // In-memory aggregates (protected by `lock`). Used for picker ordering on the hot path.
    private let lock = NSLock()
    private var lastUsedBundle: String?
    private var lastBrowserIDByBundle: [String: String] = [:]   // "bundleID" -> last-used Browser.id for that bundle
    private var bundleCounts: [String: Int] = [:]               // "bundleID" -> total clicks

    // Today's aggregates for the menubar summary (protected by `lock`).
    private var todayStart: TimeInterval = 0                    // start-of-day the counters below belong to
    private var todayCount = 0
    private var todayByBrowser: [String: Int] = [:]
    private var todayByDomain: [String: Int] = [:]

    /// Default init: uses `Config.shared.configDir`.
    init() {
        self.configDir = { Config.shared.configDir }
    }

    /// Test/DI init: point at any directory.
    init(configDir: URL) {
        self.configDir = { configDir }
    }

    var path: URL {
        configDir().appendingPathComponent("stats.jsonl")
    }

    func start() {
        queue.async { [self] in
            let fm = FileManager.default
            let dir = configDir()
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: path.path) {
                fm.createFile(atPath: path.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: path)
            _ = try? fileHandle?.seekToEnd()

            // Warm in-memory aggregates from file
            let entries = loadAll()
            var counts: [String: Int] = [:]
            var lastForBundle: [String: String] = [:]
            var lastBundle: String?
            let dayStart = Self.startOfDay(Date().timeIntervalSince1970)
            var tCount = 0
            var tBrowser: [String: Int] = [:]
            var tDomain: [String: Int] = [:]
            for e in entries {
                let bundle = Self.bundleID(fromBrowserID: e.browserID)
                counts[bundle, default: 0] += 1
                lastForBundle[bundle] = e.browserID
                lastBundle = bundle
                if e.t >= dayStart {
                    tCount += 1
                    tBrowser[e.browserName, default: 0] += 1
                    if let h = e.host, !h.isEmpty { tDomain[h, default: 0] += 1 }
                }
            }
            lock.lock()
            self.bundleCounts = counts
            self.lastBrowserIDByBundle = lastForBundle
            self.lastUsedBundle = lastBundle
            self.todayStart = dayStart
            self.todayCount = tCount
            self.todayByBrowser = tBrowser
            self.todayByDomain = tDomain
            lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didRecordNotification, object: nil)
            }
        }
    }

    func record(url: URL, browser: Browser, sourceBundleID: String?, matchedRule: Bool) {
        let entry = StatEntry(
            t: Date().timeIntervalSince1970,
            url: url.absoluteString,
            host: url.host,
            browserID: browser.id,
            browserName: browser.displayName,
            sourceApp: sourceBundleID,
            ruleMatched: matchedRule
        )

        lock.lock()
        bundleCounts[browser.bundleID, default: 0] += 1
        lastBrowserIDByBundle[browser.bundleID] = browser.id
        lastUsedBundle = browser.bundleID
        rollDayLocked(now: entry.t)
        todayCount += 1
        todayByBrowser[browser.displayName, default: 0] += 1
        if let h = url.host, !h.isEmpty { todayByDomain[h, default: 0] += 1 }
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didRecordNotification, object: nil)
        }

        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(entry) else { return }
            var line = data
            line.append(0x0a)
            try? fileHandle?.write(contentsOf: line)
        }
    }

    /// Reset today's counters if `now` has crossed into a new calendar day. Caller holds `lock`.
    private func rollDayLocked(now: TimeInterval) {
        let start = Self.startOfDay(now)
        if start != todayStart {
            todayStart = start
            todayCount = 0
            todayByBrowser = [:]
            todayByDomain = [:]
        }
    }

    /// Compact summary for the menubar (today only).
    func menubarSummary() -> MenubarSummary {
        lock.lock(); defer { lock.unlock() }
        rollDayLocked(now: Date().timeIntervalSince1970)
        func top(_ dict: [String: Int]) -> (String, Int)? {
            dict.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }
                .map { ($0.key, $0.value) }
        }
        let b = top(todayByBrowser)
        let d = top(todayByDomain)
        return MenubarSummary(
            todayCount: todayCount,
            topBrowser: b.map { ($0.0, $0.1) },
            topDomain: d.map { ($0.0, $0.1) }
        )
    }

    static func startOfDay(_ t: TimeInterval) -> TimeInterval {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: t)).timeIntervalSince1970
    }

    func loadAll() -> [StatEntry] {
        guard let data = try? Data(contentsOf: path) else { return [] }
        var out: [StatEntry] = []
        let decoder = JSONDecoder()
        data.split(separator: 0x0a).forEach { slice in
            if let e = try? decoder.decode(StatEntry.self, from: Data(slice)) {
                out.append(e)
            }
        }
        return out
    }

    /// Last-used Browser.id for a given bundle (e.g. Chrome profile memory). `nil` if never used.
    func lastBrowserID(for bundleID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastBrowserIDByBundle[bundleID]
    }

    /// Order groups by: most-recently-used first, then by count desc.
    /// No data yet → Chrome first (if present), otherwise original order.
    func sortedGroups(_ groups: [BrowserGroup]) -> [BrowserGroup] {
        guard !groups.isEmpty else { return groups }

        lock.lock()
        let last = lastUsedBundle
        let counts = bundleCounts
        lock.unlock()

        if last == nil && counts.isEmpty {
            if let i = groups.firstIndex(where: { $0.bundleID == "com.google.Chrome" }), i != 0 {
                var reorder = groups
                let chrome = reorder.remove(at: i)
                return [chrome] + reorder
            }
            return groups
        }

        var rest = groups
        var result: [BrowserGroup] = []
        if let last, let i = rest.firstIndex(where: { $0.bundleID == last }) {
            result.append(rest.remove(at: i))
        }
        rest.sort { (counts[$0.bundleID] ?? 0) > (counts[$1.bundleID] ?? 0) }
        return result + rest
    }

    /// Extract bundle from a Browser.id like "com.google.Chrome#Default" or "com.apple.Safari".
    static func bundleID(fromBrowserID id: String) -> String {
        if let hash = id.firstIndex(of: "#") { return String(id[..<hash]) }
        return id
    }

    /// Test seam: synchronously update in-memory aggregates as if `record(...)` had
    /// been called for each entry. Avoids spinning up a file handle / dispatch queue.
    func seedAggregates(from entries: [StatEntry]) {
        var counts: [String: Int] = [:]
        var lastForBundle: [String: String] = [:]
        var lastBundle: String?
        for e in entries {
            let bundle = Self.bundleID(fromBrowserID: e.browserID)
            counts[bundle, default: 0] += 1
            lastForBundle[bundle] = e.browserID
            lastBundle = bundle
        }
        lock.lock()
        self.bundleCounts = counts
        self.lastBrowserIDByBundle = lastForBundle
        self.lastUsedBundle = lastBundle
        lock.unlock()
    }
}

/// Compact stats for the menubar dropdown (today only).
struct MenubarSummary {
    let todayCount: Int
    let topBrowser: (name: String, count: Int)?
    let topDomain: (name: String, count: Int)?
}

struct StatsSnapshot {
    struct Bucket: Hashable {
        let key: String
        let count: Int
    }
    /// A day and how many links were opened that day (local calendar day).
    struct DayCount: Hashable {
        let day: Date
        let count: Int
    }

    let total: Int
    let sinceStart: Date?
    let ruleMatchedCount: Int
    let byBrowser: [Bucket]
    let byBundle: [Bucket]        // browsers rolled up across profiles ("Google Chrome" total)
    let byProfile: [Bucket]       // Chromium profile usage ("Work", "Personal", …)
    let byDomain: [Bucket]
    let byURL: [Bucket]
    let bySourceApp: [Bucket]
    let last7DaysTotal: Int
    let last24hTotal: Int

    // Time-of-day / weekday
    let byHour: [Int]             // 24 entries, index = local hour 0…23
    let byWeekday: [Int]          // 7 entries, index 0 = Sunday … 6 = Saturday
    let heatmap: [[Int]]          // [7][24] weekday × hour
    let busiestHour: (hour: Int, count: Int)?
    let weekdayCount: Int         // Mon–Fri
    let weekendCount: Int         // Sat/Sun

    // Fun stats
    let busiestDay: DayCount?
    let currentStreak: Int        // consecutive days up to the most recent active day
    let longestStreak: Int
    let activeDays: Int
    let avgPerActiveDay: Double
    let favoriteCombo: (browser: String, host: String, count: Int)?

    static func from(_ entries: [StatEntry]) -> StatsSnapshot {
        let now = Date().timeIntervalSince1970
        let day: TimeInterval = 24 * 3600
        let cal = Calendar.current

        var browser: [String: Int] = [:]
        var bundle: [String: Int] = [:]
        var profile: [String: Int] = [:]
        var domain: [String: Int] = [:]
        var urlCounts: [String: Int] = [:]
        var source: [String: Int] = [:]
        var combo: [String: (browser: String, host: String, count: Int)] = [:]
        var ruleMatched = 0
        var last7 = 0
        var last24 = 0
        var earliest: TimeInterval? = nil

        var hours = [Int](repeating: 0, count: 24)
        var weekdays = [Int](repeating: 0, count: 7)
        var heat = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 7)
        var weekdayTotal = 0
        var weekendTotal = 0
        var perDay: [Date: Int] = [:]

        for e in entries {
            browser[e.browserName, default: 0] += 1
            let parts = splitBrowserName(e.browserName)
            bundle[parts.base, default: 0] += 1
            if let p = parts.profile { profile[p, default: 0] += 1 }
            if let h = e.host, !h.isEmpty {
                domain[h, default: 0] += 1
                let key = "\(e.browserName)\u{1}\(h)"
                let prev = combo[key]?.count ?? 0
                combo[key] = (e.browserName, h, prev + 1)
            }
            urlCounts[e.url, default: 0] += 1
            if let s = e.sourceApp, !s.isEmpty { source[s, default: 0] += 1 }
            if e.ruleMatched { ruleMatched += 1 }
            if now - e.t <= 7 * day { last7 += 1 }
            if now - e.t <= day { last24 += 1 }
            if earliest == nil || e.t < earliest! { earliest = e.t }

            let date = Date(timeIntervalSince1970: e.t)
            let comps = cal.dateComponents([.hour, .weekday], from: date)
            let hour = comps.hour ?? 0
            let weekdayIdx = (comps.weekday ?? 1) - 1     // Calendar weekday is 1…7 (Sun…Sat)
            hours[hour] += 1
            weekdays[weekdayIdx] += 1
            heat[weekdayIdx][hour] += 1
            if weekdayIdx == 0 || weekdayIdx == 6 { weekendTotal += 1 } else { weekdayTotal += 1 }
            perDay[cal.startOfDay(for: date), default: 0] += 1
        }

        func top(_ dict: [String: Int], limit: Int) -> [Bucket] {
            dict.map { Bucket(key: $0.key, count: $0.value) }
                .sorted {
                    // Tiebreak alphabetically so tied rows don't swap on each refresh.
                    if $0.count != $1.count { return $0.count > $1.count }
                    return $0.key < $1.key
                }
                .prefix(limit)
                .map { $0 }
        }

        // Busiest hour
        var busiestHour: (hour: Int, count: Int)? = nil
        for (h, c) in hours.enumerated() where c > 0 {
            if busiestHour == nil || c > busiestHour!.count { busiestHour = (h, c) }
        }

        // Busiest day + streaks
        var busiestDay: DayCount? = nil
        for (d, c) in perDay {
            if busiestDay == nil || c > busiestDay!.count ||
               (c == busiestDay!.count && d > busiestDay!.day) {
                busiestDay = DayCount(day: d, count: c)
            }
        }
        let sortedDays = perDay.keys.sorted()
        var longest = 0, current = 0
        var prev: Date? = nil
        for d in sortedDays {
            if let p = prev, let next = cal.date(byAdding: .day, value: 1, to: p), cal.isDate(next, inSameDayAs: d) {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
            prev = d
        }
        // currentStreak = run ending on the most recent active day.
        var currentStreak = 0
        if let last = sortedDays.last {
            currentStreak = 1
            var cursor = last
            let daySet = Set(sortedDays)
            while let earlier = cal.date(byAdding: .day, value: -1, to: cursor),
                  daySet.contains(cal.startOfDay(for: earlier)) {
                currentStreak += 1
                cursor = cal.startOfDay(for: earlier)
            }
        }

        let favorite = combo.values.max {
            $0.count != $1.count ? $0.count < $1.count : $0.host > $1.host
        }

        return StatsSnapshot(
            total: entries.count,
            sinceStart: earliest.map { Date(timeIntervalSince1970: $0) },
            ruleMatchedCount: ruleMatched,
            byBrowser: top(browser, limit: 20),
            byBundle: top(bundle, limit: 12),
            byProfile: top(profile, limit: 12),
            byDomain: top(domain, limit: 15),
            byURL: top(urlCounts, limit: 15),
            bySourceApp: top(source, limit: 10),
            last7DaysTotal: last7,
            last24hTotal: last24,
            byHour: hours,
            byWeekday: weekdays,
            heatmap: heat,
            busiestHour: busiestHour,
            weekdayCount: weekdayTotal,
            weekendCount: weekendTotal,
            busiestDay: busiestDay,
            currentStreak: currentStreak,
            longestStreak: longest,
            activeDays: perDay.count,
            avgPerActiveDay: perDay.isEmpty ? 0 : Double(entries.count) / Double(perDay.count),
            favoriteCombo: favorite.map { ($0.browser, $0.host, $0.count) }
        )
    }
}
