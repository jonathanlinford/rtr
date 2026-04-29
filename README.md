# rtr

A native macOS default-browser picker. When you click a link anywhere on your
Mac, `rtr` intercepts it, applies any rules you've configured, and either
opens it in the right browser automatically or shows a fast picker UI.

- **Per-domain / per-source-app rules** — open `*.github.com` in Chrome, your
  bank in Safari, links from Slack in Arc, etc.
- **Chromium profile aware** — route to `Google Chrome — Work` instead of just
  "Chrome".
- **Native-app deep links** — `slack.com/...`, `zoom.us/j/...`, Spotify, and
  Discord links are rewritten to open in their respective apps.
- **Stats** — local-only history of which links opened where.
- **Menubar** — quick access to config, stats, and login-item toggle.

## Install

Requires macOS 13+ and Swift 5.9+.

```sh
./build.sh run
```

This builds, installs to `~/Applications/rtr.app`, and launches the app.
Then go to **System Settings → Desktop & Dock → Default web browser → rtr**.

Other targets:

```sh
./build.sh           # build into ./build/rtr.app
./build.sh install   # build + install to ~/Applications
```

## Configuration

`rtr` reads `~/.config/rtr/config.json`. Edit it from the menubar
(*Edit Config*) or directly. First match wins.

```json
{
  "default_browser": null,
  "rules": [
    { "domain": "github.com",       "browser": "com.google.Chrome#Default" },
    { "domain": "mybank.example",   "browser": "com.apple.Safari" },
    { "source_app": "com.tinyspeck.slackmacgap",
                                    "browser": "chrome:Work" },
    { "regex": "^https?://(localhost|127\\.0\\.0\\.1)",
                                    "browser": "com.brave.Browser" }
  ]
}
```

Browser identifiers can be:

- A bundle ID — `com.apple.Safari`
- A bundle ID + Chromium profile directory — `com.google.Chrome#Default`
- A friendly alias — `chrome:Work`, `safari`, `firefox`, `arc`

A rule's matchers are AND'd together; multiple rules are OR'd in declaration
order.

Supported matchers:

| key          | meaning                                                    |
| ------------ | ---------------------------------------------------------- |
| `domain`     | exact host or suffix match (`github.com` ⇒ `*.github.com`) |
| `substring`  | substring of the full URL                                  |
| `regex`      | NSRegularExpression on the full URL                        |
| `source_app` | bundle ID of the app that triggered the link               |

Each accepts a string or an array of strings.

## Stats

`rtr` records each link open to `~/.config/rtr/stats.jsonl`. Open the stats
window from the menubar to see totals, top browsers, top domains, and source
apps. Nothing leaves your machine.

## Privacy

See [PRIVACY.md](PRIVACY.md). Short version: stats are local, no telemetry,
favicon images are fetched from public icon services keyed by hostname.

## Development

```sh
swift build               # debug build
./test.sh                 # run unit tests (works with CLT-only or full Xcode)
./build.sh                # produce the .app bundle
```

> `./test.sh` falls back to `swift test` and only adds extra flags if you
> have Command Line Tools installed but not full Xcode (Swift Testing's
> framework isn't on the default search path in that setup).

The codebase is small and split by concern:

| file                  | purpose                                          |
| --------------------- | ------------------------------------------------ |
| `main.swift`          | NSApplication entry point                        |
| `AppDelegate.swift`   | URL event handling, menubar, login item          |
| `Config.swift`        | JSON config parsing + rule matching              |
| `BrowserCatalog.swift`| Discovery + grouping of installed browsers       |
| `ChromiumProfiles.swift` | Reads `Local State` for Chromium profiles      |
| `DeepLinks.swift`     | URL → native-app-scheme rewriters                |
| `PickerWindow.swift`  | The picker HUD and rule-form UI                  |
| `Stats.swift`         | JSONL log + in-memory aggregates                 |
| `StatsWindow.swift`   | Stats window UI                                  |
| `FaviconCache.swift`  | Favicon fetcher (memory + disk)                  |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
