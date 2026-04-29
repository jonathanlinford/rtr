import AppKit

struct Browser: Hashable {
    enum Kind: Hashable {
        case simple
        case chromium(profileDir: String, profileName: String)
        /// Route to a native app via a rewritten URL (e.g. https://slack.com/... → slack://...).
        case deepLink(rewrittenURL: URL)
    }
    let id: String
    let displayName: String
    let bundleID: String
    let appURL: URL
    let kind: Kind
    /// For Chromium browsers: resolved path to the profile's GAIA avatar PNG, if any.
    /// Always `nil` for non-Chromium kinds.
    let chromiumAvatarURL: URL?

    init(id: String, displayName: String, bundleID: String, appURL: URL,
         kind: Kind, chromiumAvatarURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.bundleID = bundleID
        self.appURL = appURL
        self.kind = kind
        self.chromiumAvatarURL = chromiumAvatarURL
    }

    var isChromium: Bool {
        if case .chromium = kind { return true }
        return false
    }

    var chromiumProfileName: String? {
        if case .chromium(_, let name) = kind { return name }
        return nil
    }

    func open(url: URL) {
        switch kind {
        case .deepLink(let rewritten):
            // The rewritten URL's scheme (slack://, zoommtg://, etc.) uniquely identifies
            // the target app, so plain NSWorkspace.open is enough — no need to force appURL.
            NSWorkspace.shared.open(rewritten)
            return

        case .simple:
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false
            config.arguments = [url.absoluteString]
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
                if let error = error {
                    NSLog("rtr launch failed: \(error.localizedDescription)")
                }
            }

        case .chromium(let profileDir, _):
            // NSWorkspace.open drops --profile-directory when Chrome is already running
            // (URL lands in whichever profile window is focused). Invoke the binary directly
            // so Chrome's own IPC honors the flag and routes the URL to the right profile.
            let execURL = appURL.appendingPathComponent("Contents/MacOS/\(chromiumExecutableName(for: appURL))")
            let proc = Process()
            proc.executableURL = execURL
            proc.arguments = ["--profile-directory=\(profileDir)", url.absoluteString]
            do {
                try proc.run()
                // Bring the browser forward — launching the binary doesn't activate it.
                NSWorkspace.shared.open(appURL)
            } catch {
                NSLog("rtr chromium launch failed: \(error.localizedDescription) — falling back to NSWorkspace")
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                config.createsNewApplicationInstance = false
                config.arguments = ["--profile-directory=\(profileDir)", url.absoluteString]
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config, completionHandler: nil)
            }
        }
    }
}

/// Chromium apps name their executable after the app bundle (e.g. "Google Chrome",
/// "Google Chrome Beta", "Brave Browser"). Read CFBundleExecutable from Info.plist.
private func chromiumExecutableName(for appURL: URL) -> String {
    if let bundle = Bundle(url: appURL),
       let name = bundle.infoDictionary?["CFBundleExecutable"] as? String {
        return name
    }
    return appURL.deletingPathExtension().lastPathComponent
}

/// Groups browsers for rendering (e.g., Chrome rolled up with a profile dropdown).
struct BrowserGroup {
    let displayName: String
    let bundleID: String
    let appURL: URL
    let browsers: [Browser]
    var isChromium: Bool { browsers.first?.isChromium ?? false }
}

final class BrowserCatalog {
    static let shared = BrowserCatalog()

    private(set) var all: [Browser] = []
    private(set) var groups: [BrowserGroup] = []

    private let chromiumBundles: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.vivaldi.Vivaldi": "Vivaldi"
    ]

    func refresh() {
        let probe = URL(string: "https://example.com")!
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: probe)

        var result: [Browser] = []
        var groups: [BrowserGroup] = []
        let selfBundle = Bundle.main.bundleIdentifier ?? "com.jonny.rtr"
        let displayMode = Settings.profileDisplay

        for appURL in appURLs {
            guard let bundle = Bundle(url: appURL),
                  let bundleID = bundle.bundleIdentifier,
                  bundleID != selfBundle else { continue }

            let displayName = (FileManager.default.displayName(atPath: appURL.path) as NSString)
                .deletingPathExtension

            if let supportSubpath = chromiumBundles[bundleID] {
                let profiles = ChromiumProfiles.load(supportSubpath: supportSubpath)
                if !profiles.isEmpty {
                    let profileBrowsers = profiles.map { p in
                        Browser(
                            id: "\(bundleID)#\(p.directory)",
                            displayName: "\(displayName) — \(p.name)",
                            bundleID: bundleID,
                            appURL: appURL,
                            kind: .chromium(profileDir: p.directory, profileName: p.name),
                            chromiumAvatarURL: p.avatarURL
                        )
                    }
                    result.append(contentsOf: profileBrowsers)

                    switch displayMode {
                    case .grouped:
                        groups.append(BrowserGroup(
                            displayName: displayName,
                            bundleID: bundleID,
                            appURL: appURL,
                            browsers: profileBrowsers
                        ))
                    case .flat:
                        // One group per profile, so each becomes its own row.
                        for b in profileBrowsers {
                            groups.append(BrowserGroup(
                                displayName: b.displayName,
                                bundleID: bundleID,
                                appURL: appURL,
                                browsers: [b]
                            ))
                        }
                    }
                    continue
                }
            }

            let browser = Browser(
                id: bundleID,
                displayName: displayName,
                bundleID: bundleID,
                appURL: appURL,
                kind: .simple
            )
            result.append(browser)
            groups.append(BrowserGroup(
                displayName: displayName,
                bundleID: bundleID,
                appURL: appURL,
                browsers: [browser]
            ))
        }

        self.all = result
        self.groups = groups
    }

    /// Native (non-browser) apps that can open this URL, sourced from our DeepLinks
    /// rewriter (services with proprietary schemes like slack://, zoommtg://).
    ///
    /// We deliberately do NOT call `NSWorkspace.urlsForApplications(toOpen: url)` with
    /// an https URL here — on recent macOS that probes Associated Domains and can
    /// surface a "allow this app to use saved Passkeys?" prompt. Almost no macOS apps
    /// register for https handlers anyway, so the LaunchServices path wasn't worth it.
    func nativeHandlerGroups(for url: URL) -> [BrowserGroup] {
        let browserBundles = Set(groups.map(\.bundleID))
        let selfBundle = Bundle.main.bundleIdentifier ?? "com.jonny.rtr"
        var seen = Set<String>()
        var result: [BrowserGroup] = []

        for match in DeepLinks.resolve(for: url) {
            let bundleID = match.handler.bundleID
            guard bundleID != selfBundle,
                  !browserBundles.contains(bundleID),
                  seen.insert(bundleID).inserted else { continue }
            let browser = Browser(
                id: bundleID,
                displayName: match.handler.name,
                bundleID: bundleID,
                appURL: match.appURL,
                kind: .deepLink(rewrittenURL: match.deepLinkURL)
            )
            result.append(BrowserGroup(
                displayName: match.handler.name,
                bundleID: bundleID,
                appURL: match.appURL,
                browsers: [browser]
            ))
        }
        return result
    }

    /// Resolve a rule's browser reference. Accepts several forms:
    /// - "com.apple.Safari" — bundle ID (simple browser)
    /// - "com.google.Chrome#Default" — bundle ID + Chromium profile directory
    /// - "chrome:Work" — friendly "chrome" alias + profile display name
    /// - "safari", "firefox", "arc" — friendly name fuzzy match
    func find(id: String) -> Browser? {
        Self.resolve(id: id, in: all)
    }

    /// Pure resolver — exposed for unit tests.
    static func resolve(id: String, in browsers: [Browser]) -> Browser? {
        if let exact = browsers.first(where: { $0.id == id }) { return exact }

        if id.contains(":") {
            let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
            let alias = parts[0].lowercased()
            let profile = parts[1]
            return browsers.first {
                guard case .chromium(_, let name) = $0.kind else { return false }
                return $0.displayName.lowercased().contains(alias) &&
                       name.caseInsensitiveCompare(profile) == .orderedSame
            }
        }

        // Friendly name fuzzy match on simple browsers
        let lower = id.lowercased()
        if let hit = browsers.first(where: {
            if case .simple = $0.kind {
                return $0.displayName.lowercased().contains(lower) ||
                       $0.bundleID.lowercased().contains(lower)
            }
            return false
        }) { return hit }

        return nil
    }
}
