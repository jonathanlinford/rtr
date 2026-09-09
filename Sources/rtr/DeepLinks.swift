import AppKit

/// Translates a web URL to a native-app deep link for apps that only register a custom
/// scheme (not https). LaunchServices can't surface these via `urlsForApplications`,
/// so we maintain per-service rewriters here.
struct DeepLinkHandler {
    let name: String
    let bundleID: String
    let matches: (URL) -> Bool
    let rewrite: (URL) -> URL?
}

enum DeepLinks {
    static let all: [DeepLinkHandler] = [
        DeepLinkHandler(
            name: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            matches: { $0.host?.hasSuffix(".slack.com") == true },
            rewrite: slackRewrite
        ),
        DeepLinkHandler(
            name: "Zoom",
            bundleID: "us.zoom.xos",
            matches: { url in
                guard let host = url.host,
                      host == "zoom.us" || host.hasSuffix(".zoom.us") else { return false }
                return url.path.hasPrefix("/j/") || url.path.hasPrefix("/my/")
            },
            rewrite: zoomRewrite
        ),
        DeepLinkHandler(
            name: "Spotify",
            bundleID: "com.spotify.client",
            matches: { $0.host == "open.spotify.com" },
            rewrite: spotifyRewrite
        ),
        DeepLinkHandler(
            name: "Discord",
            bundleID: "com.hnc.Discord",
            matches: { url in
                (url.host == "discord.com" || url.host == "discordapp.com")
                && url.path.hasPrefix("/channels/")
            },
            rewrite: discordRewrite
        ),
    ]

    struct Match {
        let handler: DeepLinkHandler
        let deepLinkURL: URL
        let appURL: URL
    }

    static func resolve(for url: URL) -> [Match] {
        var results: [Match] = []
        for h in all where h.matches(url) {
            guard let rewritten = h.rewrite(url),
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: h.bundleID)
            else { continue }
            results.append(Match(handler: h, deepLinkURL: rewritten, appURL: appURL))
        }
        return results
    }
}

// MARK: - Per-service rewriters

/// Resolves a workspace subdomain (e.g. "heyhalda") to its Slack team ID (e.g. "T7H6W50RX")
/// by reading Slack's local app state. The `slack://` scheme's `team` parameter requires the
/// team ID, not the subdomain — passing the subdomain makes Slack surface without navigating.
enum SlackTeams {
    private static let stateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Slack/storage/root-state.json")

    // Cache the parsed map keyed by the file's mtime so a workspace add/remove is picked up
    // without re-parsing on every click.
    private static var cache: (mtime: Date, map: [String: String])?

    /// Returns the team ID for a subdomain, or nil if Slack isn't installed, the state file's
    /// moved, or that workspace isn't signed in.
    static func teamID(forSubdomain subdomain: String) -> String? {
        loadMap()?[subdomain.lowercased()]
    }

    private static func loadMap() -> [String: String]? {
        let path = stateURL.path
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return cache?.map }
        if let c = cache, c.mtime == mtime { return c.map }

        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaces = root["workspaces"] as? [String: Any]
        else { return cache?.map }

        var map: [String: String] = [:]
        for entry in workspaces.values {
            guard let dict = entry as? [String: Any],
                  let domain = dict["domain"] as? String,
                  let id = dict["id"] as? String else { continue }
            map[domain.lowercased()] = id
        }
        cache = (mtime, map)
        return map
    }
}

private func slackRewrite(_ url: URL) -> URL? {
    slackRewrite(url, resolveTeamID: SlackTeams.teamID(forSubdomain:))
}

/// Injectable core so the team-ID lookup can be stubbed in tests.
func slackRewrite(_ url: URL, resolveTeamID: (String) -> String?) -> URL? {
    guard let host = url.host, host.hasSuffix(".slack.com") else { return nil }
    let subdomain = String(host.dropLast(".slack.com".count))
    // Slack needs the team ID; fall back to the subdomain (opens the app, no navigation) only
    // when we can't resolve it — no worse than before.
    let team = resolveTeamID(subdomain) ?? subdomain

    var comp = URLComponents()
    comp.scheme = "slack"

    let parts = url.pathComponents  // ["/", "archives", "<channel>", "p<ts16>"]
    if parts.count >= 4, parts[1] == "archives" {
        let channel = parts[2]
        let pts = parts[3]
        var items: [URLQueryItem] = [
            URLQueryItem(name: "team", value: team),
            URLQueryItem(name: "id", value: channel),
        ]
        // p1234567890123456 → 1234567890.123456 (Slack's dotted ts format)
        if pts.hasPrefix("p"), pts.count == 17 {
            let digits = String(pts.dropFirst())
            let idx = digits.index(digits.startIndex, offsetBy: 10)
            let ts = "\(digits[..<idx]).\(digits[idx...])"
            items.append(URLQueryItem(name: "message", value: ts))
        }
        if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let tt = q.first(where: { $0.name == "thread_ts" })?.value {
            items.append(URLQueryItem(name: "thread_ts", value: tt))
        }
        comp.host = "channel"
        comp.queryItems = items
        return comp.url
    }

    // Fallback: workspace root — open the team in the app.
    comp.host = "open"
    comp.queryItems = [URLQueryItem(name: "team", value: team)]
    return comp.url
}

private func zoomRewrite(_ url: URL) -> URL? {
    let parts = url.pathComponents  // ["/", "j", "<id>"]
    guard parts.count >= 3, parts[1] == "j" else { return nil }
    let confno = parts[2]
    var items: [URLQueryItem] = [URLQueryItem(name: "confno", value: confno)]
    if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
       let pwd = q.first(where: { $0.name == "pwd" })?.value {
        items.append(URLQueryItem(name: "pwd", value: pwd))
    }
    var comp = URLComponents()
    comp.scheme = "zoommtg"
    comp.host = "zoom.us"
    comp.path = "/join"
    comp.queryItems = items
    return comp.url
}

private func spotifyRewrite(_ url: URL) -> URL? {
    // /track/<id>, /album/<id>, /playlist/<id>, /artist/<id>
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count >= 2 else { return URL(string: "spotify:") }
    return URL(string: "spotify:\(parts[0]):\(parts[1])")
}

private func discordRewrite(_ url: URL) -> URL? {
    // Discord's scheme accepts its web paths verbatim under discord://-/...
    URL(string: "discord://-\(url.path)")
}
