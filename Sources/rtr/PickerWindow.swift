import AppKit

final class PickerWindowController: NSObject, NSWindowDelegate {
    private var window: RtrPanel!
    private var contentView: PickerContentView!
    private var onChoose: ((Browser) -> Void)?

    func prewarm() {
        let frame = NSRect(x: 0, y: 0, width: 480, height: 420)
        let window = RtrPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = .popUpMenu
        window.hidesOnDeactivate = true
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        // Lock the content width so a long URL can't push the panel off-screen.
        window.contentMinSize = NSSize(width: 480, height: 0)
        window.contentMaxSize = NSSize(width: 480, height: 4000)
        window.delegate = self

        let content = PickerContentView(frame: frame)
        content.onChoose = { [weak self] browser in self?.commit(browser) }
        content.onCancel = { [weak self] in self?.dismiss() }
        window.contentView = content
        // Hard width constraint — contentMinSize/contentMaxSize only govern user resize,
        // not Auto Layout's fitting size. Without this a giant URL grows the panel.
        content.widthAnchor.constraint(equalToConstant: 480).isActive = true

        self.window = window
        self.contentView = content
    }

    func show(url: URL, sourceBundleID: String?, completion: @escaping (Browser) -> Void) {
        self.onChoose = completion
        // Native handlers (Slack.app for slack.com, etc.) are pinned at the top so the
        // "open in the real app" choice is always the first hotkey. Browsers follow,
        // sorted by usage.
        let nativeGroups = BrowserCatalog.shared.nativeHandlerGroups(for: url)
        let browserGroups = Stats.shared.sortedGroups(BrowserCatalog.shared.groups)
        let ordered = nativeGroups + browserGroups
        contentView.configure(url: url, sourceBundleID: sourceBundleID, groups: ordered)
        sizeToFit(groupCount: ordered.count)
        positionOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func sizeToFit(groupCount: Int) {
        let headerH: CGFloat = 78    // top padding + URL line + source line
        let rowH: CGFloat = 46       // row height + spacing
        let bottomH: CGFloat = 46    // hint area + spacing
        // Rule form needs ~160; use whichever's larger so it fits when toggled.
        let rowsHeight = CGFloat(max(1, groupCount)) * rowH
        let contentHeight = headerH + max(rowsHeight, 170) + bottomH
        let capped = min(contentHeight, (NSScreen.main?.visibleFrame.height ?? 900) * 0.85)
        window.setContentSize(NSSize(width: 480, height: capped))
    }

    private func positionOnActiveScreen() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let sf = screen.visibleFrame
        let wf = window.frame
        let x = sf.minX + (sf.width - wf.width) / 2
        let y = sf.minY + (sf.height - wf.height) * 0.6
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func commit(_ browser: Browser) {
        let cb = onChoose
        onChoose = nil
        window.orderOut(nil)
        cb?(browser)
    }

    private func dismiss() {
        onChoose = nil
        window.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if window.isVisible { dismiss() }
    }
}

final class RtrPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class PickerContentView: NSView {
    var onChoose: ((Browser) -> Void)?
    var onCancel: (() -> Void)?

    private let headerFavicon = NSImageView()
    private let headerURL = NSTextField(labelWithString: "")
    private let headerSource = NSTextField(labelWithString: "")
    private var faviconRequestToken: UUID?
    private let hint = NSTextField(labelWithString: "")
    private let rowStack = NSStackView()
    private let ruleButton = ChipButton()
    private let ruleForm = RuleFormView()
    private var rowViews: [BrowserRowView] = []
    private var selectedIndex: Int = 0

    private var currentURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1

        headerFavicon.imageScaling = .scaleProportionallyDown
        headerFavicon.translatesAutoresizingMaskIntoConstraints = false
        headerFavicon.contentTintColor = Theme.placeholderTint
        headerFavicon.image = Self.placeholderFavicon

        headerURL.font = .systemFont(ofSize: 13, weight: .medium)
        headerURL.textColor = Theme.primaryText
        headerURL.lineBreakMode = .byTruncatingMiddle
        headerURL.maximumNumberOfLines = 1
        headerURL.cell?.usesSingleLineMode = true
        headerURL.cell?.truncatesLastVisibleLine = true
        headerURL.translatesAutoresizingMaskIntoConstraints = false
        // A multi-kilobyte URL's intrinsic width must never push the panel wider.
        headerURL.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerURL.setContentHuggingPriority(.defaultLow, for: .horizontal)

        headerSource.font = .systemFont(ofSize: 11)
        headerSource.textColor = Theme.secondaryText
        headerSource.translatesAutoresizingMaskIntoConstraints = false

        hint.font = .systemFont(ofSize: 10)
        hint.textColor = Theme.quaternaryText
        hint.stringValue = "↑↓/⇥ move • ⏎ open • ⎋ cancel • 1–9 hotkey"
        hint.translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.spacing = 2
        rowStack.alignment = .leading
        rowStack.distribution = .fill
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        ruleButton.title = "+ Rule"
        ruleButton.translatesAutoresizingMaskIntoConstraints = false
        ruleButton.onClick = { [weak self] in self?.setRuleFormVisible(true) }

        ruleForm.translatesAutoresizingMaskIntoConstraints = false
        ruleForm.isHidden = true
        ruleForm.onCancel = { [weak self] in self?.setRuleFormVisible(false) }
        ruleForm.onSave = { [weak self] matcher, value, browser in
            _ = Config.shared.appendRule(matcher: matcher, value: value, browserID: browser.id)
            self?.onChoose?(browser)
        }

        addSubview(headerFavicon)
        addSubview(headerURL)
        addSubview(ruleButton)
        addSubview(headerSource)
        addSubview(rowStack)
        addSubview(ruleForm)
        addSubview(hint)

        NSLayoutConstraint.activate([
            headerFavicon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerFavicon.centerYAnchor.constraint(equalTo: headerURL.centerYAnchor),
            headerFavicon.widthAnchor.constraint(equalToConstant: 16),
            headerFavicon.heightAnchor.constraint(equalToConstant: 16),

            headerURL.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            headerURL.leadingAnchor.constraint(equalTo: headerFavicon.trailingAnchor, constant: 8),
            headerURL.trailingAnchor.constraint(equalTo: ruleButton.leadingAnchor, constant: -10),

            ruleButton.centerYAnchor.constraint(equalTo: headerURL.centerYAnchor),
            ruleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            headerSource.topAnchor.constraint(equalTo: headerURL.bottomAnchor, constant: 4),
            headerSource.leadingAnchor.constraint(equalTo: headerURL.leadingAnchor),
            headerSource.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            rowStack.topAnchor.constraint(equalTo: headerSource.bottomAnchor, constant: 14),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            ruleForm.topAnchor.constraint(equalTo: headerSource.bottomAnchor, constant: 14),
            ruleForm.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            ruleForm.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])

        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: Theme.appearanceDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func themeChanged() { applyTheme() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        layer?.backgroundColor = Theme.panelBackground.cgColor(for: effectiveAppearance)
        layer?.borderColor = Theme.panelBorder.cgColor(for: effectiveAppearance)
    }

    func configure(url: URL, sourceBundleID: String?, groups: [BrowserGroup]) {
        currentURL = url
        headerURL.stringValue = url.absoluteString
        loadFavicon(for: url)
        if let src = sourceBundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: src).first {
            let name = app.localizedName ?? src
            headerSource.stringValue = "from \(name)"
        } else {
            headerSource.stringValue = "from (unknown)"
        }

        rebuildRows(groups: groups)
        setRuleFormVisible(false)
    }

    private func loadFavicon(for url: URL) {
        let token = UUID()
        faviconRequestToken = token
        // Show cached value immediately if we have it, else a placeholder while we fetch.
        if let hit = FaviconCache.shared.cachedImage(for: url) {
            headerFavicon.image = hit
            return
        }
        headerFavicon.image = Self.placeholderFavicon
        FaviconCache.shared.favicon(for: url) { [weak self] image in
            guard let self, self.faviconRequestToken == token, let image else { return }
            self.headerFavicon.image = image
        }
    }

    private static let placeholderFavicon: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let img = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }()

    private func rebuildRows(groups: [BrowserGroup]) {
        for v in rowViews { v.removeFromSuperview() }
        rowViews.removeAll()

        for (i, group) in groups.enumerated() {
            let hotkey = i < 9 ? String(i + 1) : ""
            let row = BrowserRowView(group: group, hotkey: hotkey)
            row.onChoose = { [weak self] browser in self?.onChoose?(browser) }
            row.onHover = { [weak self] in self?.setSelectedIndex(i) }
            rowViews.append(row)
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor, constant: 0).isActive = true
        }
        selectedIndex = 0
        applySelectionHighlight()
    }

    private func setSelectedIndex(_ idx: Int) {
        guard !rowViews.isEmpty else { return }
        let count = rowViews.count
        let wrapped = ((idx % count) + count) % count
        if wrapped == selectedIndex { return }
        selectedIndex = wrapped
        applySelectionHighlight()
    }

    private func applySelectionHighlight() {
        for (i, row) in rowViews.enumerated() {
            row.setSelected(i == selectedIndex)
        }
    }

    private func setRuleFormVisible(_ visible: Bool) {
        ruleForm.isHidden = !visible
        rowStack.isHidden = visible
        ruleButton.isHidden = visible
        hint.stringValue = visible
            ? "⏎ save & open • ⎋ cancel"
            : "↑↓/⇥ move • ⏎ open • ⎋ cancel • 1–9 hotkey"
        if visible, let url = currentURL {
            let defaultBrowser = rowViews.first?.currentBrowser ?? BrowserCatalog.shared.all.first
            ruleForm.reset(url: url, browsers: BrowserCatalog.shared.all, defaultBrowser: defaultBrowser)
            window?.makeFirstResponder(ruleForm.valueField)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Esc
            if !ruleForm.isHidden { setRuleFormVisible(false); return }
            onCancel?()
            return
        case 36, 76:  // Enter / numpad Enter
            if !ruleForm.isHidden { ruleForm.submit(); return }
            if selectedIndex >= 0 && selectedIndex < rowViews.count {
                rowViews[selectedIndex].trigger()
            }
            return
        default: break
        }

        if !ruleForm.isHidden { super.keyDown(with: event); return }

        switch event.keyCode {
        case 125:  // Down arrow
            setSelectedIndex(selectedIndex + 1); return
        case 126:  // Up arrow
            setSelectedIndex(selectedIndex - 1); return
        case 48:   // Tab (shift+Tab walks backwards)
            let delta = event.modifierFlags.contains(.shift) ? -1 : 1
            setSelectedIndex(selectedIndex + delta); return
        default: break
        }

        if let chars = event.charactersIgnoringModifiers, let digit = Int(chars), digit >= 1 && digit <= rowViews.count {
            rowViews[digit - 1].trigger()
            return
        }

        super.keyDown(with: event)
    }
}

final class BrowserRowView: NSView {
    let group: BrowserGroup
    var onChoose: ((Browser) -> Void)?
    var onHover: (() -> Void)?

    private let hotkeyBadge = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let button = HoverButton()
    private var profilePill: ProfilePill?
    private var trackingArea: NSTrackingArea?

    private var isHovering = false
    private var isSelected = false

    /// Currently-selected browser variant; for Chromium groups this reflects the pill.
    private(set) var currentBrowser: Browser

    init(group: BrowserGroup, hotkey: String) {
        self.group = group
        // Pick starting profile: last-used (from Stats) > first.
        if group.browsers.count > 1,
           let lastID = Stats.shared.lastBrowserID(for: group.bundleID),
           let match = group.browsers.first(where: { $0.id == lastID }) {
            self.currentBrowser = match
        } else {
            self.currentBrowser = group.browsers.first!
        }

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        hotkeyBadge.stringValue = hotkey
        hotkeyBadge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        hotkeyBadge.textColor = Theme.tertiaryText
        hotkeyBadge.alignment = .center
        hotkeyBadge.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSWorkspace.shared.icon(forFile: group.appURL.path)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.stringValue = group.displayName
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = Theme.primaryText
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        button.title = ""
        button.isBordered = false
        button.target = self
        button.action = #selector(rowClicked)
        button.translatesAutoresizingMaskIntoConstraints = false

        addSubview(button)          // full-row click target (behind)
        addSubview(hotkeyBadge)
        addSubview(iconView)
        addSubview(nameLabel)

        var trailingPin: NSLayoutXAxisAnchor = trailingAnchor

        if case .deepLink = currentBrowser.kind {
            let badge = DeepLinkBadge()
            badge.translatesAutoresizingMaskIntoConstraints = false
            addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                badge.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            trailingPin = badge.leadingAnchor
        }

        if group.isChromium && group.browsers.count > 1 {
            let pill = ProfilePill()
            pill.setProfiles(
                group.browsers.map { (id: $0.id, name: $0.chromiumProfileName ?? $0.displayName) },
                selectedID: currentBrowser.id
            )
            pill.onSelect = { [weak self] id in
                guard let self, let b = self.group.browsers.first(where: { $0.id == id }) else { return }
                self.currentBrowser = b
                self.onChoose?(b)    // auto-launch on profile change
            }
            pill.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pill)
            profilePill = pill
            NSLayoutConstraint.activate([
                pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                pill.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            trailingPin = pill.leadingAnchor
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),

            hotkeyBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            hotkeyBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            hotkeyBadge.widthAnchor.constraint(equalToConstant: 16),

            iconView.leadingAnchor.constraint(equalTo: hotkeyBadge.trailingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingPin, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        onHover?()
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    func setSelected(_ selected: Bool) {
        if isSelected == selected { return }
        isSelected = selected
        updateAppearance()
    }

    private func updateAppearance() {
        let color: NSColor
        if isSelected {
            color = Theme.rowSelectedBackground
        } else if isHovering {
            color = Theme.rowHoverBackground
        } else {
            color = .clear
        }
        layer?.backgroundColor = color.cgColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    @objc private func rowClicked() { trigger() }

    func trigger() {
        onChoose?(currentBrowser)
    }
}

/// Invisible button that doesn't intercept mouseEntered/Exited on its parent.
final class HoverButton: NSButton {
    override var wantsDefaultClipping: Bool { false }
}

/// Small "↗ App" pill indicating a row will route through a native-app deep link,
/// not the browser. Visual-only; clicks pass through to the underlying row button.
final class DeepLinkBadge: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        icon.image?.isTemplate = true
        icon.contentTintColor = NSColor.systemBlue.withAlphaComponent(0.95)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "App")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor.systemBlue.withAlphaComponent(0.95)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // Pass clicks through so hitting the badge still selects the row.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Modern pill-style dropdown replacement for NSPopUpButton. Menu-driven selection.
final class ProfilePill: NSControl {
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var profiles: [(id: String, name: String)] = []
    private(set) var selectedID: String?
    var onSelect: ((String) -> Void)?
    private var tracking: NSTrackingArea?
    private var isHovering = false { didSet { updateAppearance() } }
    private var isPressed = false { didSet { updateAppearance() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        updateAppearance()

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = Theme.pillLabel
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 1

        let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        chevron.contentTintColor = Theme.placeholderTint
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(chevron)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setProfiles(_ ps: [(id: String, name: String)], selectedID: String?) {
        self.profiles = ps
        self.selectedID = selectedID
        let name = ps.first(where: { $0.id == selectedID })?.name ?? ps.first?.name ?? ""
        label.stringValue = name
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent)  { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        let menu = NSMenu()
        menu.autoenablesItems = false
        for p in profiles {
            let item = NSMenuItem(title: p.name, action: #selector(didPick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.id
            if p.id == selectedID { item.state = .on }
            menu.addItem(item)
        }
        let origin = NSPoint(x: 0, y: bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: self)
        isPressed = false
    }

    @objc private func didPick(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        selectedID = id
        label.stringValue = profiles.first(where: { $0.id == id })?.name ?? ""
        onSelect?(id)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let bg: NSColor
        if isPressed { bg = Theme.pillBackgroundPressed }
        else if isHovering { bg = Theme.pillBackgroundHover }
        else { bg = Theme.pillBackground }
        layer?.backgroundColor = bg.cgColor(for: effectiveAppearance)
        let border = isHovering ? Theme.pillBorderHover : Theme.pillBorder
        layer?.borderColor = border.cgColor(for: effectiveAppearance)
    }
}

/// Small rounded chip button — matches pill styling.
final class ChipButton: NSControl {
    private let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var isHovering = false { didSet { updateAppearance() } }
    private var isPressed = false { didSet { updateAppearance() } }

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.pillLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        ])
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent)  { isHovering = false }
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        onClick?()
        isPressed = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let bg: NSColor
        if isPressed { bg = Theme.pillBackgroundPressed }
        else if isHovering { bg = Theme.pillBackgroundHover }
        else { bg = Theme.pillBackground }
        layer?.backgroundColor = bg.cgColor(for: effectiveAppearance)
        let border = isHovering ? Theme.pillBorderHover : Theme.pillBorder
        layer?.borderColor = border.cgColor(for: effectiveAppearance)
    }
}

/// Inline form for creating a routing rule from the current URL.
final class RuleFormView: NSView {
    var onCancel: (() -> Void)?
    var onSave: ((Config.MatcherKind, String, Browser) -> Void)?

    private let matcherPill = ProfilePill()
    private let browserPill = ProfilePill()
    let valueField = RuleTextField()
    private let saveButton = PrimaryButton()
    private let cancelButton = ChipButton()

    private var matcher: Config.MatcherKind = .domain
    private var browsers: [Browser] = []
    private var selectedBrowser: Browser?
    private var url: URL?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: Theme.appearanceDidChange, object: nil)

        let matchLabel = Self.fieldLabel("Match by")
        let openLabel = Self.fieldLabel("Open in")

        matcherPill.setProfiles([
            ("domain", "Domain"),
            ("substring", "Substring"),
            ("regex", "Regex")
        ], selectedID: "domain")
        matcherPill.onSelect = { [weak self] id in
            guard let self, let kind = Config.MatcherKind(rawValue: id) else { return }
            self.matcher = kind
            if let url = self.url {
                self.valueField.stringValue = Self.suggestedValue(matcher: kind, url: url)
            }
        }

        browserPill.onSelect = { [weak self] id in
            self?.selectedBrowser = self?.browsers.first(where: { $0.id == id })
        }

        valueField.placeholderString = "value"
        valueField.onSubmit = { [weak self] in self?.submit() }
        valueField.onEscape = { [weak self] in self?.onCancel?() }

        saveButton.title = "Save & Open"
        saveButton.onClick = { [weak self] in self?.submit() }

        cancelButton.title = "Cancel"
        cancelButton.onClick = { [weak self] in self?.onCancel?() }

        let topRow = NSStackView(views: [matchLabel, matcherPill, valueField])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.alignment = .centerY
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let midRow = NSStackView(views: [openLabel, browserPill])
        midRow.orientation = .horizontal
        midRow.spacing = 8
        midRow.alignment = .centerY
        midRow.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let actionRow = NSStackView(views: [spacer, cancelButton, saveButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        actionRow.alignment = .centerY
        actionRow.distribution = .fill
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [topRow, midRow, actionRow])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),

            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            midRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),

            matchLabel.widthAnchor.constraint(equalToConstant: 64),
            openLabel.widthAnchor.constraint(equalToConstant: 64),
            matcherPill.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            valueField.heightAnchor.constraint(equalToConstant: 24),
            browserPill.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func reset(url: URL, browsers: [Browser], defaultBrowser: Browser?) {
        self.url = url
        self.browsers = browsers
        self.matcher = .domain
        matcherPill.setProfiles([
            ("domain", "Domain"),
            ("substring", "Substring"),
            ("regex", "Regex")
        ], selectedID: "domain")
        browserPill.setProfiles(browsers.map { ($0.id, $0.displayName) },
                                selectedID: defaultBrowser?.id ?? browsers.first?.id)
        selectedBrowser = defaultBrowser ?? browsers.first
        valueField.stringValue = Self.suggestedValue(matcher: .domain, url: url)
    }

    func submit() {
        let value = valueField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, let browser = selectedBrowser else {
            NSSound.beep()
            return
        }
        onSave?(matcher, value, browser)
    }

    @objc private func themeChanged() { applyTheme() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        layer?.backgroundColor = Theme.formBackground.cgColor(for: effectiveAppearance)
        layer?.borderColor = Theme.formBorder.cgColor(for: effectiveAppearance)
    }

    private static func fieldLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 11, weight: .medium)
        f.textColor = Theme.secondaryText
        return f
    }

    private static func suggestedValue(matcher: Config.MatcherKind, url: URL) -> String {
        let host = url.host ?? ""
        switch matcher {
        case .domain: return host
        case .substring: return host
        case .regex:
            let escaped = NSRegularExpression.escapedPattern(for: host)
            return "^https?://(?:.+\\.)?\(escaped)"
        case .source_app: return ""
        }
    }
}

/// Text field styled for the dark HUD, with Enter submit.
final class RuleTextField: NSTextField, NSTextFieldDelegate {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        textColor = Theme.primaryText
        font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: Theme.appearanceDidChange, object: nil)
        delegate = self
    }

    @objc private func themeChanged() { applyTheme() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        layer?.backgroundColor = Theme.textFieldBackground.cgColor(for: effectiveAppearance)
        layer?.borderColor = Theme.textFieldBorder.cgColor(for: effectiveAppearance)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 24)
    }

    // Insets the text so the first glyph isn't hugging the border.
    private class InsetCell: NSTextFieldCell {
        private let inset = NSSize(width: 8, height: 3)
        override func titleRect(forBounds rect: NSRect) -> NSRect {
            return super.titleRect(forBounds: rect).insetBy(dx: inset.width, dy: inset.height)
        }
        override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
            super.edit(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
        }
        override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start: Int, length: Int) {
            super.select(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: start, length: length)
        }
        override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
            super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
        }
    }

    override class var cellClass: AnyClass? {
        get { InsetCell.self }
        set { }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onSubmit?()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape?()
            return true
        }
        return false
    }
}

/// Primary-action button: filled accent pill.
final class PrimaryButton: NSControl {
    private let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var isHovering = false { didSet { updateAppearance() } }
    private var isPressed = false { didSet { updateAppearance() } }

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent)  { isHovering = false }
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        onClick?()
        isPressed = false
    }

    private func updateAppearance() {
        let accent = NSColor.controlAccentColor
        let alpha: CGFloat = isPressed ? 0.95 : (isHovering ? 0.85 : 0.75)
        layer?.backgroundColor = accent.withAlphaComponent(alpha).cgColor
    }
}
