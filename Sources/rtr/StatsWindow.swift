import AppKit

/// How the charts are scoped when the user clicks a browser/profile row.
enum StatsFilter: Equatable {
    case browser(String)   // exact recorded browserName ("Google Chrome — Work")
    case bundle(String)    // base app across profiles ("Google Chrome")
    case profile(String)   // Chromium profile name ("Work")

    var label: String {
        switch self {
        case .browser(let n): return n
        case .bundle(let b):  return b
        case .profile(let p): return "Profile · \(p)"
        }
    }

    func matches(_ e: StatEntry) -> Bool {
        let parts = splitBrowserName(e.browserName)
        switch self {
        case .browser(let n): return e.browserName == n
        case .bundle(let b):  return parts.base == b
        case .profile(let p): return parts.profile == p
        }
    }
}

final class StatsWindowController: NSWindowController {
    private var content: StatsContentView!

    private var tab = 0
    private var range: StatsRange = .all
    private var filter: StatsFilter?

    private let tabTitles = ["Overview", "Browsers", "Domains", "Time", "Fun"]

    convenience init() {
        let frame = NSRect(x: 0, y: 0, width: 860, height: 660)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "rtr — Stats"
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 640, height: 480)

        self.init(window: window)

        content = StatsContentView(frame: frame, tabTitles: tabTitles,
                                   rangeTitles: StatsRange.allCases.map(\.label),
                                   selectedRange: StatsRange.allCases.firstIndex(of: range) ?? 0)
        content.onTabChange = { [weak self] i in self?.tab = i; self?.rebuild() }
        content.onRangeChange = { [weak self] i in
            self?.range = StatsRange.allCases[i]; self?.rebuild()
        }
        content.onClearFilter = { [weak self] in self?.filter = nil; self?.rebuild() }
        window.contentView = content

        NotificationCenter.default.addObserver(
            self, selector: #selector(statsDidChange),
            name: Stats.didRecordNotification, object: nil)

        rebuild()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func statsDidChange() {
        guard window?.isVisible == true else { return }
        rebuild()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        rebuild()
    }

    // MARK: - Page building

    private func rebuild() {
        var entries = Stats.shared.loadAll()
        let now = Date().timeIntervalSince1970
        entries = range.filter(entries, now: now)
        if let filter { entries = entries.filter(filter.matches) }
        let snap = StatsSnapshot.from(entries)

        content.setFilter(filter?.label, onClear: { [weak self] in self?.filter = nil; self?.rebuild() })
        content.setPage(makePage(tab, snap: snap))
    }

    private func applyFilter(_ f: StatsFilter) {
        filter = (filter == f) ? nil : f
        rebuild()
    }

    private func makePage(_ tab: Int, snap: StatsSnapshot) -> NSView {
        switch tab {
        case 1:  return browsersPage(snap)
        case 2:  return domainsPage(snap)
        case 3:  return timePage(snap)
        case 4:  return funPage(snap)
        default: return overviewPage(snap)
        }
    }

    private func page(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Every direct child spans the full page width.
        for v in views {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func headerBlock(_ snap: StatsSnapshot) -> NSView {
        let header = NSTextField(labelWithString: "\(snap.total) links opened")
        header.font = .systemFont(ofSize: 28, weight: .bold)
        header.textColor = StatsTheme.primary

        let f = DateFormatter(); f.dateStyle = .medium
        let since = snap.sinceStart.map(f.string(from:)) ?? "—"
        let rulePct = snap.total > 0 ? Int(Double(snap.ruleMatchedCount) / Double(snap.total) * 100) : 0
        let subhead = NSTextField(labelWithString:
            "Tracking since \(since)   •   \(rulePct)% auto-routed by rules   •   \(range.label)")
        subhead.font = .systemFont(ofSize: 12)
        subhead.textColor = StatsTheme.secondary

        let s = NSStackView(views: [header, subhead])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        return s
    }

    private func cardRow(_ cards: [NSView]) -> NSStackView {
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 12
        return row
    }

    private func overviewPage(_ snap: StatsSnapshot) -> NSView {
        let cards = cardRow([
            StatCard(title: "Total", value: snap.total, accent: StatsTheme.blue),
            StatCard(title: "Last 24h", value: snap.last24hTotal, accent: StatsTheme.teal),
            StatCard(title: "Last 7d", value: snap.last7DaysTotal, accent: StatsTheme.green),
            StatCard(title: "Auto-routed",
                     value: snap.total > 0 ? Int(Double(snap.ruleMatchedCount) / Double(snap.total) * 100) : 0,
                     accent: StatsTheme.orange, suffix: "%"),
        ])
        let browsers = BarSection(title: "Top Browsers & Profiles", buckets: snap.byBrowser,
                                  accent: StatsTheme.blue,
                                  onSelect: { [weak self] in self?.applyFilter(.browser($0)) })
        let domains = BarSection(title: "Top Domains", buckets: snap.byDomain, accent: StatsTheme.teal)
        return page([headerBlock(snap), cards, browsers, domains])
    }

    private func browsersPage(_ snap: StatsSnapshot) -> NSView {
        let bundles = BarSection(title: "Browsers (all profiles)", buckets: snap.byBundle,
                                 accent: StatsTheme.blue,
                                 onSelect: { [weak self] in self?.applyFilter(.bundle($0)) })
        let profiles = BarSection(title: "Chrome Profiles", buckets: snap.byProfile,
                                  accent: StatsTheme.purple,
                                  onSelect: { [weak self] in self?.applyFilter(.profile($0)) })
        let full = BarSection(title: "Every Browser + Profile", buckets: snap.byBrowser,
                              accent: StatsTheme.teal,
                              onSelect: { [weak self] in self?.applyFilter(.browser($0)) })
        return page([bundles, profiles, full])
    }

    private func domainsPage(_ snap: StatsSnapshot) -> NSView {
        var views: [NSView] = []
        if let combo = snap.favoriteCombo {
            views.append(cardRow([
                FunCard(icon: "star.fill", title: "Favorite combo",
                        value: splitBrowserName(combo.browser).profile ?? combo.browser,
                        subtitle: "\(combo.host) · \(combo.count) links", accent: StatsTheme.pink),
            ]))
        }
        views.append(BarSection(title: "Top Domains", buckets: snap.byDomain, accent: StatsTheme.teal))
        views.append(BarSection(title: "Top URLs", buckets: snap.byURL,
                                accent: StatsTheme.purple, monospaced: true))
        views.append(BarSection(title: "Top Source Apps", buckets: snap.bySourceApp, accent: StatsTheme.orange))
        return page(views)
    }

    private func timePage(_ snap: StatsSnapshot) -> NSView {
        let caption = NSTextField(labelWithString: " ")
        caption.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        caption.textColor = StatsTheme.secondary

        let hist = HourHistogramView(data: snap.byHour, accent: StatsTheme.orange,
                                     busiest: snap.busiestHour?.hour)
        hist.caption = caption

        let heat = HeatmapView(data: snap.heatmap, accent: StatsTheme.orange)
        heat.caption = caption

        let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let weekdayBuckets = (0..<7).map {
            StatsSnapshot.Bucket(key: weekdayNames[$0], count: snap.byWeekday[$0])
        }
        let weekday = BarSection(title: "By Weekday", buckets: weekdayBuckets, accent: StatsTheme.teal)

        let busiestHourText = snap.busiestHour.map { String(format: "%02d:00", $0.hour) } ?? "—"
        let cards = cardRow([
            FunCard(icon: "clock.fill", title: "Busiest hour", value: busiestHourText,
                    subtitle: snap.busiestHour.map { "\($0.count) links" }, accent: StatsTheme.orange),
            FunCard(icon: "briefcase.fill", title: "Weekday", value: "\(snap.weekdayCount)",
                    subtitle: "Mon–Fri", accent: StatsTheme.blue),
            FunCard(icon: "sun.max.fill", title: "Weekend", value: "\(snap.weekendCount)",
                    subtitle: "Sat/Sun", accent: StatsTheme.green),
        ])

        return page([
            cards,
            sectionTitle("Links by hour of day"), hist,
            weekday,
            sectionTitle("Hour × weekday heatmap"), heat,
            caption,
        ])
    }

    private func funPage(_ snap: StatsSnapshot) -> NSView {
        let f = DateFormatter(); f.dateStyle = .medium
        var cards: [NSView] = []

        cards.append(FunCard(icon: "flame.fill", title: "Longest streak",
                             value: "\(snap.longestStreak) day\(snap.longestStreak == 1 ? "" : "s")",
                             subtitle: "consecutive active days", accent: StatsTheme.orange))
        cards.append(FunCard(icon: "bolt.fill", title: "Current streak",
                             value: "\(snap.currentStreak) day\(snap.currentStreak == 1 ? "" : "s")",
                             subtitle: "up to the latest day", accent: StatsTheme.pink))
        cards.append(FunCard(icon: "calendar", title: "Busiest day",
                             value: snap.busiestDay.map { f.string(from: $0.day) } ?? "—",
                             subtitle: snap.busiestDay.map { "\($0.count) links" }, accent: StatsTheme.purple))
        cards.append(FunCard(icon: "chart.bar.fill", title: "Avg / active day",
                             value: String(format: "%.1f", snap.avgPerActiveDay),
                             subtitle: "\(snap.activeDays) active day\(snap.activeDays == 1 ? "" : "s")",
                             accent: StatsTheme.teal))
        if let combo = snap.favoriteCombo {
            cards.append(FunCard(icon: "star.fill", title: "Favorite combo",
                                 value: splitBrowserName(combo.browser).profile ?? combo.browser,
                                 subtitle: "\(combo.host) · \(combo.count)×", accent: StatsTheme.blue))
        }
        cards.append(FunCard(icon: "arrow.triangle.branch", title: "Auto-routed",
                             value: snap.total > 0 ? "\(Int(Double(snap.ruleMatchedCount) / Double(snap.total) * 100))%" : "—",
                             subtitle: "\(snap.ruleMatchedCount) by rules", accent: StatsTheme.green))

        // 2-up grid.
        var rows: [NSView] = []
        var i = 0
        while i < cards.count {
            let slice = Array(cards[i..<min(i + 2, cards.count)])
            let padded: [NSView] = slice.count == 2 ? slice : [slice[0], NSView()]
            rows.append(cardRow(padded))
            i += 2
        }
        return page(rows)
    }
}

// MARK: - Content shell (toolbar + scrolling page)

/// Top-left origin so documents lay out top-down and scroll-to-top shows the header.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class StatsContentView: NSView {
    var onTabChange: ((Int) -> Void)?
    var onRangeChange: ((Int) -> Void)?
    var onClearFilter: (() -> Void)?

    private let tabSelector: SegmentedSelector
    private let rangeSelector: SegmentedSelector
    private let scroll = NSScrollView()
    private let pageHost = FlippedView()
    private var currentPage: NSView?
    private var chip: FilterChip?
    private let chipRow = NSView()
    private var chipRowHeight: NSLayoutConstraint!

    init(frame frameRect: NSRect, tabTitles: [String], rangeTitles: [String], selectedRange: Int) {
        tabSelector = SegmentedSelector(titles: tabTitles, accent: StatsTheme.blue)
        rangeSelector = SegmentedSelector(titles: rangeTitles, accent: StatsTheme.green, selected: selectedRange)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = StatsTheme.background.cgColor

        tabSelector.onSelect = { [weak self] i in self?.onTabChange?(i) }
        rangeSelector.onSelect = { [weak self] i in self?.onRangeChange?(i) }

        let toolbar = NSStackView(views: [tabSelector, rangeSelector])
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        tabSelector.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rangeSelector.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(toolbar)

        chipRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chipRow)
        chipRowHeight = chipRow.heightAnchor.constraint(equalToConstant: 0)
        chipRowHeight.isActive = true

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        addSubview(scroll)

        pageHost.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = pageHost

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            rangeSelector.widthAnchor.constraint(equalToConstant: 200),

            chipRow.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            chipRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            chipRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: chipRow.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            pageHost.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setPage(_ view: NSView) {
        currentPage?.removeFromSuperview()
        currentPage = view
        view.translatesAutoresizingMaskIntoConstraints = false
        pageHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: pageHost.topAnchor, constant: 20),
            view.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor, constant: 24),
            view.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor, constant: -24),
            view.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor, constant: -24),
        ])
        // Reset scroll to top on page swap.
        scroll.documentView?.scroll(NSPoint(x: 0, y: 0))
    }

    func setFilter(_ label: String?, onClear: @escaping () -> Void) {
        chip?.removeFromSuperview()
        chip = nil
        guard let label else { chipRowHeight.constant = 0; return }
        let c = FilterChip(text: label)
        c.onClear = onClear
        chipRow.addSubview(c)
        NSLayoutConstraint.activate([
            c.leadingAnchor.constraint(equalTo: chipRow.leadingAnchor),
            c.centerYAnchor.constraint(equalTo: chipRow.centerYAnchor),
        ])
        chip = c
        chipRowHeight.constant = 28
    }
}
