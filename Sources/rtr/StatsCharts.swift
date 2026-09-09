import AppKit

// MARK: - Theme

enum StatsTheme {
    static let background = NSColor(calibratedWhite: 0.10, alpha: 1.0)
    static let card       = NSColor(calibratedWhite: 1, alpha: 0.06)
    static let hairline   = NSColor(calibratedWhite: 1, alpha: 0.09)
    static let primary    = NSColor.white
    static let secondary  = NSColor(calibratedWhite: 1, alpha: 0.55)
    static let tertiary   = NSColor(calibratedWhite: 1, alpha: 0.35)

    // Per-tab accent colors.
    static let blue   = NSColor.systemBlue
    static let teal   = NSColor.systemTeal
    static let purple = NSColor.systemPurple
    static let orange = NSColor.systemOrange
    static let pink   = NSColor.systemPink
    static let green  = NSColor.systemGreen
}

// MARK: - Sliding segmented selector

/// A pill-style segmented control with an animated sliding highlight. Used for
/// both the tab bar and the time-range switcher.
final class SegmentedSelector: NSView {
    private let titles: [String]
    private let accent: NSColor
    private var buttons: [NSButton] = []
    private let highlight = NSView()
    private(set) var selectedIndex = 0
    var onSelect: ((Int) -> Void)?

    init(titles: [String], accent: NSColor, selected: Int = 0) {
        self.titles = titles
        self.accent = accent
        self.selectedIndex = min(max(selected, 0), max(titles.count - 1, 0))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = StatsTheme.card.cgColor

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.layer?.backgroundColor = accent.withAlphaComponent(0.30).cgColor
        highlight.layer?.borderWidth = 1
        highlight.layer?.borderColor = accent.withAlphaComponent(0.5).cgColor
        addSubview(highlight)

        for (i, t) in titles.enumerated() {
            let b = NSButton(title: t, target: self, action: #selector(tap(_:)))
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.focusRingType = .none
            b.tag = i
            addSubview(b)
            buttons.append(b)
        }
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        updateTitleColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let n = CGFloat(buttons.count)
        guard n > 0, bounds.width > 0 else { return }
        let pad: CGFloat = 3
        let w = (bounds.width - pad * 2) / n
        for (i, b) in buttons.enumerated() {
            b.frame = NSRect(x: pad + CGFloat(i) * w, y: 0, width: w, height: bounds.height)
        }
        positionHighlight(animated: false)
    }

    private func positionHighlight(animated: Bool) {
        guard selectedIndex < buttons.count else { return }
        let target = buttons[selectedIndex].frame.insetBy(dx: 2, dy: 3)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                highlight.animator().frame = target
            }
        } else {
            highlight.frame = target
        }
    }

    @objc private func tap(_ sender: NSButton) {
        guard sender.tag != selectedIndex else { return }
        select(sender.tag, animated: true)
        onSelect?(sender.tag)
    }

    func select(_ index: Int, animated: Bool) {
        guard index >= 0, index < buttons.count else { return }
        selectedIndex = index
        positionHighlight(animated: animated)
        updateTitleColors()
    }

    private func updateTitleColors() {
        for (i, b) in buttons.enumerated() {
            let selected = i == selectedIndex
            b.attributedTitle = NSAttributedString(string: titles[i], attributes: [
                .foregroundColor: selected ? StatsTheme.primary : StatsTheme.secondary,
                .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .medium)
            ])
        }
    }
}

// MARK: - Animated bar

/// A rounded track with a fill that grows from the left on first appearance.
final class BarView: NSView {
    private let fill = CALayer()
    private var didAnimate = false
    var fraction: CGFloat = 0
    var animationDelay: CFTimeInterval = 0
    var accent: NSColor = StatsTheme.blue {
        didSet { fill.backgroundColor = accent.withAlphaComponent(0.65).cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.05).cgColor
        layer?.masksToBounds = true
        fill.cornerRadius = 5
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.backgroundColor = accent.withAlphaComponent(0.65).cgColor
        layer?.addSublayer(fill)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        let w = fraction > 0 ? max(bounds.width * fraction, 6) : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.position = CGPoint(x: 0, y: bounds.midY)
        fill.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        CATransaction.commit()

        if !didAnimate {
            didAnimate = true
            let anim = CABasicAnimation(keyPath: "bounds.size.width")
            anim.fromValue = 0
            anim.toValue = w
            anim.duration = 0.6
            anim.beginTime = CACurrentMediaTime() + animationDelay
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            anim.fillMode = .backwards
            fill.add(anim, forKey: "grow")
        }
    }

    func setHighlighted(_ on: Bool) {
        fill.backgroundColor = accent.withAlphaComponent(on ? 0.95 : 0.65).cgColor
    }
}

/// One labelled bar row, with hover highlight and optional click-to-filter.
final class AnimatedBarRow: NSView {
    var onClick: (() -> Void)?
    private let bar = BarView()
    private let labelField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private let clickable: Bool

    init(label: String, count: Int, fraction: Double, accent: NSColor,
         monospaced: Bool, index: Int, clickable: Bool) {
        self.clickable = clickable
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5

        bar.fraction = CGFloat(min(max(fraction, 0), 1))
        bar.accent = accent
        bar.animationDelay = Double(index) * 0.035
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        labelField.font = monospaced
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 12)
        labelField.textColor = StatsTheme.primary
        labelField.lineBreakMode = .byTruncatingMiddle
        labelField.maximumNumberOfLines = 1
        labelField.stringValue = label
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countField.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        countField.textColor = StatsTheme.secondary
        countField.alignment = .right
        countField.stringValue = "\(count)"
        countField.translatesAutoresizingMaskIntoConstraints = false
        countField.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(labelField)
        addSubview(countField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),

            labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: countField.leadingAnchor, constant: -8),

            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),
            countField.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func resetCursorRects() {
        if clickable { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseEntered(with event: NSEvent) {
        bar.setHighlighted(true)
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.05).cgColor
        countField.textColor = StatsTheme.primary
    }
    override func mouseExited(with event: NSEvent) {
        bar.setHighlighted(false)
        layer?.backgroundColor = NSColor.clear.cgColor
        countField.textColor = StatsTheme.secondary
    }
    override func mouseDown(with event: NSEvent) {
        if clickable { onClick?() }
    }
}

/// A titled group of bar rows.
final class BarSection: NSView {
    init(title: String, buckets: [StatsSnapshot.Bucket], accent: NSColor,
         monospaced: Bool = false, startIndex: Int = 0, onSelect: ((String) -> Void)? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let t = NSTextField(labelWithString: title.uppercased())
        t.font = .systemFont(ofSize: 10, weight: .semibold)
        t.textColor = StatsTheme.secondary

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 3
        container.translatesAutoresizingMaskIntoConstraints = false

        let maxCount = buckets.map(\.count).max() ?? 1
        if buckets.isEmpty {
            let empty = NSTextField(labelWithString: "No data yet.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = StatsTheme.tertiary
            container.addArrangedSubview(empty)
        } else {
            for (i, bucket) in buckets.enumerated() {
                let row = AnimatedBarRow(
                    label: bucket.key,
                    count: bucket.count,
                    fraction: Double(bucket.count) / Double(maxCount),
                    accent: accent,
                    monospaced: monospaced,
                    index: startIndex + i,
                    clickable: onSelect != nil
                )
                if let onSelect {
                    row.onClick = { onSelect(bucket.key) }
                }
                container.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            }
        }

        let s = NSStackView(views: [t, container])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 10
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)

        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: topAnchor),
            s.leadingAnchor.constraint(equalTo: leadingAnchor),
            s.trailingAnchor.constraint(equalTo: trailingAnchor),
            s.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.widthAnchor.constraint(equalTo: s.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Stat card (count-up)

final class StatCard: NSView {
    private let valueField = NSTextField(labelWithString: "")
    private var timer: Timer?
    private let target: Int
    private let suffix: String

    /// Numeric card that counts up on appear.
    init(title: String, value: Int, accent: NSColor = StatsTheme.blue, suffix: String = "") {
        self.target = value
        self.suffix = suffix
        super.init(frame: .zero)
        build(title: title, accent: accent)
        animateCount()
    }

    /// Static-text card (no count-up).
    init(title: String, text: String, accent: NSColor = StatsTheme.blue) {
        self.target = 0
        self.suffix = ""
        super.init(frame: .zero)
        build(title: title, accent: accent)
        valueField.stringValue = text
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    private func build(title: String, accent: NSColor) {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = StatsTheme.card.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let accentBar = NSView()
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = accent.withAlphaComponent(0.9).cgColor
        accentBar.layer?.cornerRadius = 2
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 11, weight: .medium)
        t.textColor = StatsTheme.secondary

        valueField.font = .systemFont(ofSize: 26, weight: .bold)
        valueField.textColor = StatsTheme.primary

        let s = NSStackView(views: [t, valueField])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 82),
            accentBar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 3),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            s.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            s.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])
    }

    private func animateCount() {
        guard target > 0 else { valueField.stringValue = "0\(suffix)"; return }
        let steps = 24
        var step = 0
        valueField.stringValue = "0\(suffix)"
        let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            step += 1
            let p = min(1, Double(step) / Double(steps))
            let eased = 1 - pow(1 - p, 3)
            let v = Int((Double(self.target) * eased).rounded())
            self.valueField.stringValue = "\(v)\(self.suffix)"
            if p >= 1 { timer.invalidate() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }
}

/// A larger "fun fact" card with an SF Symbol, a headline value and a caption.
final class FunCard: NSView {
    init(icon: String, title: String, value: String, subtitle: String?, accent: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = StatsTheme.card.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            iconView.image = img
        }
        iconView.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        iconView.contentTintColor = accent
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: title.uppercased())
        titleField.font = .systemFont(ofSize: 10, weight: .semibold)
        titleField.textColor = StatsTheme.secondary

        let valueField = NSTextField(labelWithString: value)
        valueField.font = .systemFont(ofSize: 22, weight: .bold)
        valueField.textColor = StatsTheme.primary
        valueField.lineBreakMode = .byTruncatingTail
        valueField.maximumNumberOfLines = 1

        let column = NSStackView(views: [titleField, valueField])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3

        if let subtitle {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = StatsTheme.tertiary
            sub.lineBreakMode = .byTruncatingTail
            sub.maximumNumberOfLines = 1
            column.addArrangedSubview(sub)
        }
        column.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(column)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 96),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            column.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Hour-of-day histogram

final class HourHistogramView: NSView {
    private let data: [Int]        // 24
    private let accent: NSColor
    private let busiest: Int?      // busiest hour index
    private var barLayers: [CALayer] = []
    private var didAnimate = false
    weak var caption: NSTextField?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { false }

    init(data: [Int], accent: NSColor, busiest: Int?) {
        self.data = data.count == 24 ? data : [Int](repeating: 0, count: 24)
        self.accent = accent
        self.busiest = busiest
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        for i in 0..<24 {
            let l = CALayer()
            l.cornerRadius = 3
            l.anchorPoint = CGPoint(x: 0.5, y: 0)
            l.backgroundColor = (i == busiest ? accent.withAlphaComponent(0.95)
                                              : accent.withAlphaComponent(0.5)).cgColor
            layer?.addSublayer(l)
            barLayers.append(l)
        }
        heightAnchor.constraint(equalToConstant: 140).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private let axisH: CGFloat = 18

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        let maxVal = max(data.max() ?? 1, 1)
        let plotH = bounds.height - axisH
        let gap: CGFloat = 3
        let barW = (bounds.width - gap * 23) / 24

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in barLayers.enumerated() {
            let h = plotH * CGFloat(data[i]) / CGFloat(maxVal)
            let x = CGFloat(i) * (barW + gap)
            l.position = CGPoint(x: x + barW / 2, y: axisH)
            l.bounds = CGRect(x: 0, y: 0, width: barW, height: max(h, data[i] > 0 ? 3 : 0))
        }
        CATransaction.commit()

        if !didAnimate {
            didAnimate = true
            for (i, l) in barLayers.enumerated() {
                let anim = CABasicAnimation(keyPath: "bounds.size.height")
                anim.fromValue = 0
                anim.toValue = l.bounds.height
                anim.duration = 0.5
                anim.beginTime = CACurrentMediaTime() + Double(i) * 0.015
                anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                anim.fillMode = .backwards
                l.add(anim, forKey: "grow")
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: StatsTheme.tertiary,
        ]
        let gap: CGFloat = 3
        let barW = (bounds.width - gap * 23) / 24
        for hour in stride(from: 0, to: 24, by: 3) {
            let x = CGFloat(hour) * (barW + gap)
            let label = String(format: "%02d", hour)
            let str = NSAttributedString(string: label, attributes: attrs)
            str.draw(at: NSPoint(x: x, y: 2))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let gap: CGFloat = 3
        let barW = (bounds.width - gap * 23) / 24
        let idx = Int(p.x / (barW + gap))
        guard idx >= 0, idx < 24 else { return }
        let c = data[idx]
        caption?.stringValue = String(format: "%02d:00 — %d link%@", idx, c, c == 1 ? "" : "s")
    }
    override func mouseExited(with event: NSEvent) {
        caption?.stringValue = " "
    }
}

// MARK: - Hour × weekday heatmap

final class HeatmapView: NSView {
    private let data: [[Int]]     // [7][24]
    private let accent: NSColor
    private let maxVal: Int
    weak var caption: NSTextField?
    private var tracking: NSTrackingArea?

    private let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private let gutter: CGFloat = 34
    private let axisH: CGFloat = 16
    private let cellGap: CGFloat = 2

    override var isFlipped: Bool { true }

    init(data: [[Int]], accent: NSColor) {
        self.data = data
        self.accent = accent
        self.maxVal = max(data.flatMap { $0 }.max() ?? 1, 1)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 172).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private func cellSize() -> (w: CGFloat, h: CGFloat) {
        let w = (bounds.width - gutter - cellGap * 23) / 24
        let h = (bounds.height - axisH - cellGap * 6) / 7
        return (w, h)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let (cw, ch) = cellSize()
        guard cw > 0, ch > 0 else { return }

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: StatsTheme.tertiary,
        ]

        for row in 0..<7 {
            let y = CGFloat(row) * (ch + cellGap)
            NSAttributedString(string: weekdayNames[row], attributes: labelAttrs)
                .draw(at: NSPoint(x: 0, y: y + (ch - 11) / 2))
            for col in 0..<24 {
                let x = gutter + CGFloat(col) * (cw + cellGap)
                let count = data[row][col]
                let intensity = count == 0 ? 0.0 : 0.15 + 0.85 * Double(count) / Double(maxVal)
                let color = count == 0
                    ? NSColor(calibratedWhite: 1, alpha: 0.05)
                    : accent.withAlphaComponent(CGFloat(intensity))
                let rect = NSRect(x: x, y: y, width: cw, height: ch)
                let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
                color.setFill()
                path.fill()
            }
        }

        // Hour ticks along the bottom.
        let (cw2, _) = (cw, ch)
        for hour in stride(from: 0, to: 24, by: 6) {
            let x = gutter + CGFloat(hour) * (cw2 + cellGap)
            NSAttributedString(string: String(format: "%02d", hour), attributes: labelAttrs)
                .draw(at: NSPoint(x: x, y: bounds.height - axisH + 3))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)   // flipped: origin top-left
        let (cw, ch) = cellSize()
        guard cw > 0, ch > 0, p.x >= gutter else { caption?.stringValue = " "; return }
        let col = Int((p.x - gutter) / (cw + cellGap))
        let row = Int(p.y / (ch + cellGap))
        guard row >= 0, row < 7, col >= 0, col < 24 else { caption?.stringValue = " "; return }
        let c = data[row][col]
        caption?.stringValue = String(format: "%@ %02d:00 — %d link%@",
                                      weekdayNames[row], col, c, c == 1 ? "" : "s")
    }
    override func mouseExited(with event: NSEvent) {
        caption?.stringValue = " "
    }
}

// MARK: - Small helpers

/// A section title label.
func sectionTitle(_ text: String) -> NSTextField {
    let t = NSTextField(labelWithString: text.uppercased())
    t.font = .systemFont(ofSize: 10, weight: .semibold)
    t.textColor = StatsTheme.secondary
    return t
}

/// A filter chip shown when the charts are scoped to one browser.
final class FilterChip: NSView {
    var onClear: (() -> Void)?

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = StatsTheme.blue.withAlphaComponent(0.22).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = StatsTheme.blue.withAlphaComponent(0.5).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Filtered: \(text)")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = StatsTheme.primary

        let clear = NSButton(title: "✕", target: self, action: #selector(clearTapped))
        clear.isBordered = false
        clear.focusRingType = .none
        clear.attributedTitle = NSAttributedString(string: "✕", attributes: [
            .foregroundColor: StatsTheme.secondary,
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
        ])

        let s = NSStackView(views: [label, clear])
        s.orientation = .horizontal
        s.spacing = 4
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            s.centerYAnchor.constraint(equalTo: centerYAnchor),
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clearTapped() { onClear?() }
}
