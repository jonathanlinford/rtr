import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var picker: PickerWindowController!
    private var statsWindow: StatsWindowController?
    private var statusItem: NSStatusItem!
    private var loginItemMenuItem: NSMenuItem?
    private var profileDisplayMenuItems: [ProfileDisplayMode: NSMenuItem] = [:]
    private var summaryTodayItem: NSMenuItem?
    private var summaryBrowserItem: NSMenuItem?
    private var summaryDomainItem: NSMenuItem?

    private let loginItemRegisteredKey = "rtr.loginItemRegistered"

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must initialize before registering the AE handler — kAEGetURL for the URL
        // that *caused* the launch is dispatched between will/didFinishLaunching, so
        // picker/config/catalog have to exist before we register to receive it.
        Config.shared.load()
        BrowserCatalog.shared.refresh()
        Stats.shared.start()

        picker = PickerWindowController()
        picker.prewarm()

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(event:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        autoEnableLoginItemOnFirstRun()
        NotificationCenter.default.addObserver(
            self, selector: #selector(statsDidChange),
            name: Stats.didRecordNotification, object: nil)
        updateStatusBadge()
    }

    @objc private func statsDidChange() { updateStatusBadge() }

    // MARK: - Login item

    private func autoEnableLoginItemOnFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: loginItemRegisteredKey) else {
            updateLoginItemMenuState()
            return
        }
        do {
            try SMAppService.mainApp.register()
            defaults.set(true, forKey: loginItemRegisteredKey)
        } catch {
            NSLog("rtr: SMAppService.register failed: \(error.localizedDescription)")
        }
        updateLoginItemMenuState()
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                UserDefaults.standard.set(true, forKey: loginItemRegisteredKey)
            }
        } catch {
            NSLog("rtr: SMAppService toggle failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Couldn't update Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        updateLoginItemMenuState()
    }

    private func updateLoginItemMenuState() {
        loginItemMenuItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            enqueueRoute(url: url, sourceBundleID: nil)
        }
    }

    @objc func handleGetURL(event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }

        let sourceBundleID = extractSourceBundleID(from: event)
        enqueueRoute(url: url, sourceBundleID: sourceBundleID)
    }

    /// Defers routing to the main queue. On cold launch the URL event arrives before
    /// NSApp's run loop is fully started; activating the app or showing a window
    /// synchronously at that point silently fails. Dispatching guarantees the app is
    /// ready to activate and display the picker.
    private func enqueueRoute(url: URL, sourceBundleID: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.route(url: url, sourceBundleID: sourceBundleID)
        }
    }

    private func extractSourceBundleID(from event: NSAppleEventDescriptor) -> String? {
        guard let addressDesc = event.attributeDescriptor(forKeyword: keyAddressAttr) else { return nil }

        let pidDesc = addressDesc.coerce(toDescriptorType: typeKernelProcessID)
        guard let pidDesc else { return nil }

        var pid: pid_t = 0
        let data = pidDesc.data
        guard data.count >= MemoryLayout<pid_t>.size else { return nil }
        data.withUnsafeBytes { bytes in
            pid = bytes.load(as: pid_t.self)
        }
        guard pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private func route(url: URL, sourceBundleID: String?) {
        if let ruleMatch = Config.shared.match(url: url, sourceBundleID: sourceBundleID),
           let browser = BrowserCatalog.shared.find(id: ruleMatch) {
            launch(url: url, browser: browser, sourceBundleID: sourceBundleID, matchedRule: true)
            return
        }

        picker.show(url: url, sourceBundleID: sourceBundleID) { [weak self] choice in
            self?.launch(url: url, browser: choice, sourceBundleID: sourceBundleID, matchedRule: false)
        }
    }

    private func launch(url: URL, browser: Browser, sourceBundleID: String?, matchedRule: Bool) {
        browser.open(url: url)
        Stats.shared.record(url: url, browser: browser, sourceBundleID: sourceBundleID, matchedRule: matchedRule)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "rtr") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "rtr"
            }
            button.toolTip = "rtr"
        }
        let menu = NSMenu()
        menu.delegate = self

        // Light stats header (non-interactive, refreshed on open).
        let today = makeInfoItem()
        let browser = makeInfoItem()
        let domain = makeInfoItem()
        summaryTodayItem = today
        summaryBrowserItem = browser
        summaryDomainItem = domain
        menu.addItem(today)
        menu.addItem(browser)
        menu.addItem(domain)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Open Stats…", action: #selector(openStats), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Edit Config", action: #selector(editConfig), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Refresh Browsers", action: #selector(refreshBrowsers), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let loginToggle = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        menu.addItem(loginToggle)
        loginItemMenuItem = loginToggle

        let profileItem = NSMenuItem(title: "Chrome Profiles", action: nil, keyEquivalent: "")
        profileItem.submenu = buildProfileDisplayMenu()
        menu.addItem(profileItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit rtr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        menu.item(withTitle: "Quit rtr")?.target = NSApp
        statusItem.menu = menu
    }

    private func buildProfileDisplayMenu() -> NSMenu {
        let submenu = NSMenu()
        profileDisplayMenuItems.removeAll()
        for mode in ProfileDisplayMode.allCases {
            let item = NSMenuItem(title: mode.menuLabel,
                                  action: #selector(selectProfileDisplay(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            submenu.addItem(item)
            profileDisplayMenuItems[mode] = item
        }
        refreshProfileDisplayMenuState()
        return submenu
    }

    private func refreshProfileDisplayMenuState() {
        let current = Settings.profileDisplay
        for (mode, item) in profileDisplayMenuItems {
            item.state = (mode == current) ? .on : .off
        }
    }

    @objc private func selectProfileDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ProfileDisplayMode(rawValue: raw) else { return }
        Settings.profileDisplay = mode
        BrowserCatalog.shared.refresh()
        refreshProfileDisplayMenuState()
    }

    // MARK: - Menubar light stats

    private func makeInfoItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Refresh the count badge shown next to the menubar icon.
    private func updateStatusBadge() {
        guard let button = statusItem?.button else { return }
        let count = Stats.shared.menubarSummary().todayCount
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.title = count > 0 ? " \(count)" : ""
        button.toolTip = count > 0 ? "rtr — \(count) links today" : "rtr"
    }

    /// Refresh the today-summary rows at the top of the dropdown menu.
    private func refreshStatsSummary() {
        let s = Stats.shared.menubarSummary()

        func styled(_ text: String, secondary: Bool) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: secondary ? 11 : 12,
                                         weight: secondary ? .regular : .semibold),
                .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ])
        }

        func truncate(_ s: String, _ n: Int) -> String {
            s.count <= n ? s : String(s.prefix(n - 1)) + "…"
        }

        summaryTodayItem?.attributedTitle = styled(
            s.todayCount == 0 ? "No links opened today"
                              : "Today: \(s.todayCount) link\(s.todayCount == 1 ? "" : "s")",
            secondary: false)

        if let b = s.topBrowser {
            summaryBrowserItem?.attributedTitle =
                styled("Top: \(truncate(b.name, 28)) (\(b.count))", secondary: true)
            summaryBrowserItem?.isHidden = false
        } else {
            summaryBrowserItem?.isHidden = true
        }

        if let d = s.topDomain {
            summaryDomainItem?.attributedTitle =
                styled("Top domain: \(truncate(d.name, 28))", secondary: true)
            summaryDomainItem?.isHidden = false
        } else {
            summaryDomainItem?.isHidden = true
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStatsSummary()
        updateLoginItemMenuState()
        refreshProfileDisplayMenuState()
    }

    @objc private func openStats() {
        if statsWindow == nil { statsWindow = StatsWindowController() }
        statsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func editConfig() {
        let path = Config.shared.configPath
        if !FileManager.default.fileExists(atPath: path.path) {
            Config.shared.writeDefaultIfMissing()
        }
        NSWorkspace.shared.open(path)
    }

    @objc private func reloadConfig() { Config.shared.load() }
    @objc private func refreshBrowsers() { BrowserCatalog.shared.refresh() }
}
