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

final class Stats {
    static let shared = Stats()

    private let queue = DispatchQueue(label: "com.jonny.rtr.stats", qos: .utility)
    private var fileHandle: FileHandle?
    private let configDir: () -> URL

    // In-memory aggregates (protected by `lock`). Used for picker ordering on the hot path.
    private let lock = NSLock()
    private var lastUsedBundle: String?
    private var lastBrowserIDByBundle: [String: String] = [:]   // "bundleID" -> last-used Browser.id for that bundle
    private var bundleCounts: [String: Int] = [:]               // "bundleID" -> total clicks

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
        lock.unlock()

        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(entry) else { return }
            var line = data
            line.append(0x0a)
            try? fileHandle?.write(contentsOf: line)
        }
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

struct StatsSnapshot {
    struct Bucket: Hashable {
        let key: String
        let count: Int
    }
    let total: Int
    let sinceStart: Date?
    let ruleMatchedCount: Int
    let byBrowser: [Bucket]
    let byDomain: [Bucket]
    let byURL: [Bucket]
    let bySourceApp: [Bucket]
    let last7DaysTotal: Int
    let last24hTotal: Int

    static func from(_ entries: [StatEntry]) -> StatsSnapshot {
        let now = Date().timeIntervalSince1970
        let day: TimeInterval = 24 * 3600
        var browser: [String: Int] = [:]
        var domain: [String: Int] = [:]
        var urlCounts: [String: Int] = [:]
        var source: [String: Int] = [:]
        var ruleMatched = 0
        var last7 = 0
        var last24 = 0
        var earliest: TimeInterval? = nil

        for e in entries {
            browser[e.browserName, default: 0] += 1
            if let h = e.host, !h.isEmpty { domain[h, default: 0] += 1 }
            urlCounts[e.url, default: 0] += 1
            if let s = e.sourceApp, !s.isEmpty { source[s, default: 0] += 1 }
            if e.ruleMatched { ruleMatched += 1 }
            if now - e.t <= 7 * day { last7 += 1 }
            if now - e.t <= day { last24 += 1 }
            if earliest == nil || e.t < earliest! { earliest = e.t }
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

        return StatsSnapshot(
            total: entries.count,
            sinceStart: earliest.map { Date(timeIntervalSince1970: $0) },
            ruleMatchedCount: ruleMatched,
            byBrowser: top(browser, limit: 20),
            byDomain: top(domain, limit: 15),
            byURL: top(urlCounts, limit: 15),
            bySourceApp: top(source, limit: 10),
            last7DaysTotal: last7,
            last24hTotal: last24
        )
    }
}
