import AppKit

final class StatsWindowController: NSWindowController {
    private var refreshTimer: Timer?
    private var content: StatsContentView!

    convenience init() {
        let frame = NSRect(x: 0, y: 0, width: 820, height: 620)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "rtr — Stats"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)

        content = StatsContentView(frame: frame)
        window.contentView = content
        reload()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reload()
    }

    private func reload() {
        let entries = Stats.shared.loadAll()
        let snap = StatsSnapshot.from(entries)
        content.update(snap)
    }
}

final class StatsContentView: NSView {
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let header = NSTextField(labelWithString: "")
    private let subhead = NSTextField(labelWithString: "")
    private let statsRow = NSStackView()
    private let grid = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0).cgColor

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        scroll.documentView = container
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])

        header.font = .systemFont(ofSize: 28, weight: .bold)
        header.textColor = .white

        subhead.font = .systemFont(ofSize: 12)
        subhead.textColor = NSColor(calibratedWhite: 1, alpha: 0.55)

        statsRow.orientation = .horizontal
        statsRow.spacing = 12
        statsRow.distribution = .fillEqually

        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 16

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(subhead)
        stack.addArrangedSubview(statsRow)
        stack.addArrangedSubview(grid)

        statsRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ snap: StatsSnapshot) {
        header.stringValue = "\(snap.total) links opened"

        let f = DateFormatter()
        f.dateStyle = .medium
        let since = snap.sinceStart.map(f.string(from:)) ?? "—"
        let rulePct = snap.total > 0 ? Int(Double(snap.ruleMatchedCount) / Double(snap.total) * 100) : 0
        subhead.stringValue = "Tracking since \(since)   •   \(rulePct)% auto-routed by rules"

        statsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        statsRow.addArrangedSubview(StatCard(title: "Last 24h", value: "\(snap.last24hTotal)"))
        statsRow.addArrangedSubview(StatCard(title: "Last 7d", value: "\(snap.last7DaysTotal)"))
        statsRow.addArrangedSubview(StatCard(title: "Rules fired", value: "\(snap.ruleMatchedCount)"))
        statsRow.addArrangedSubview(StatCard(title: "Manual picks", value: "\(snap.total - snap.ruleMatchedCount)"))

        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        grid.addArrangedSubview(BarSection(title: "Browsers", buckets: snap.byBrowser, accent: NSColor.systemBlue))
        grid.addArrangedSubview(BarSection(title: "Top Domains", buckets: snap.byDomain, accent: NSColor.systemTeal))
        grid.addArrangedSubview(BarSection(title: "Top URLs", buckets: snap.byURL, accent: NSColor.systemPurple, monospaced: true))
        grid.addArrangedSubview(BarSection(title: "Top Source Apps", buckets: snap.bySourceApp, accent: NSColor.systemOrange))
    }
}

final class StatCard: NSView {
    init(title: String, value: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.06).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 11, weight: .medium)
        t.textColor = NSColor(calibratedWhite: 1, alpha: 0.55)

        let v = NSTextField(labelWithString: value)
        v.font = .systemFont(ofSize: 26, weight: .bold)
        v.textColor = .white

        let s = NSStackView(views: [t, v])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 78),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            s.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class BarSection: NSView {
    init(title: String, buckets: [StatsSnapshot.Bucket], accent: NSColor, monospaced: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let t = NSTextField(labelWithString: title.uppercased())
        t.font = .systemFont(ofSize: 10, weight: .semibold)
        t.textColor = NSColor(calibratedWhite: 1, alpha: 0.5)

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        container.translatesAutoresizingMaskIntoConstraints = false

        let max = buckets.map(\.count).max() ?? 1
        if buckets.isEmpty {
            let empty = NSTextField(labelWithString: "No data yet.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = NSColor(calibratedWhite: 1, alpha: 0.35)
            container.addArrangedSubview(empty)
        } else {
            for bucket in buckets {
                container.addArrangedSubview(BarRow(
                    label: bucket.key,
                    count: bucket.count,
                    fraction: Double(bucket.count) / Double(max),
                    accent: accent,
                    monospaced: monospaced
                ))
            }
        }

        let s = NSStackView(views: [t, container])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)

        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: topAnchor),
            s.leadingAnchor.constraint(equalTo: leadingAnchor),
            s.trailingAnchor.constraint(equalTo: trailingAnchor),
            s.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.widthAnchor.constraint(equalTo: s.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class BarRow: NSView {
    init(label: String, count: Int, fraction: Double, accent: NSColor, monospaced: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = accent.withAlphaComponent(0.18).cgColor
        bg.layer?.cornerRadius = 4
        bg.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = accent.withAlphaComponent(0.55).cgColor
        bar.layer?.cornerRadius = 4
        bar.translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField(labelWithString: label)
        labelField.font = monospaced
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 12)
        labelField.textColor = .white
        labelField.lineBreakMode = .byTruncatingMiddle
        labelField.maximumNumberOfLines = 1
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let countField = NSTextField(labelWithString: "\(count)")
        countField.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        countField.textColor = NSColor(calibratedWhite: 1, alpha: 0.7)
        countField.alignment = .right
        countField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(bg)
        bg.addSubview(bar)
        addSubview(labelField)
        addSubview(countField)

        let fillFraction = CGFloat(min(max(fraction, 0.02), 1.0))
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),

            bar.topAnchor.constraint(equalTo: bg.topAnchor),
            bar.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            bar.widthAnchor.constraint(equalTo: bg.widthAnchor, multiplier: fillFraction),

            labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: countField.leadingAnchor, constant: -8),

            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),
            countField.widthAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
