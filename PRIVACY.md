# Privacy

`rtr` runs entirely on your Mac. It does not send analytics, telemetry, or
crash reports anywhere.

## What's stored locally

- `~/.config/rtr/config.json` — your rules.
- `~/.config/rtr/stats.jsonl` — one line per link opened: timestamp, URL,
  host, the browser used, and the bundle ID of the source app. Used to
  populate the in-app stats window and to remember which Chromium profile
  you used most recently. Stored in plain text. You can delete it any time.
- `~/Library/Caches/com.jonny.rtr/favicons/` — cached favicon PNGs keyed by
  hostname. Safe to delete.

`rtr` does not read browser history, bookmarks, cookies, or any other
browser data.

## Network requests

The only network traffic `rtr` makes is to fetch favicons for the URL
preview shown in the picker:

1. `https://www.google.com/s2/favicons?sz=64&domain=<host>` (primary)
2. `https://icons.duckduckgo.com/ip3/<host>.ico` (fallback)

Only the **hostname** of the link you're about to open is sent — never the
full URL, query string, or path. These services may log IP addresses per
their own privacy policies. If you'd rather not contact them at all, you
can block both hosts at the network level; the picker will fall back to a
generic globe icon.

`rtr` does not call any other network endpoints.

## Reading source-app information

When a link is delivered via Apple Events (the same path used by every
default-browser app on macOS), the OS includes the PID of the app that
sent it. `rtr` resolves that PID to a bundle ID locally so you can write
rules like "Slack links open in Arc". This information stays on your
machine.

## Login item

If you let `rtr` register itself as a login item, that registration is
stored by macOS in `SMAppService` — not by `rtr`. Toggle it from the
menubar at any time.
