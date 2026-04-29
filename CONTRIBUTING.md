# Contributing

Thanks for your interest in `rtr`!

## Quick start

```sh
swift build       # debug build
swift test        # run unit tests
./build.sh run    # produce a signed .app bundle and launch it
```

Requires macOS 13+ and Swift 5.9+.

## Submitting a change

1. Open an issue first if the change is non-trivial — it's much easier to
   align on an approach before code review.
2. Keep PRs focused. One concern per PR.
3. Add or update unit tests for any pure logic you touch
   (`Tests/rtrTests/`). Pure transformations (URL rewriting, rule
   matching, stats aggregation) are easy to test and worth covering.
4. Run `swift test` and `./build.sh` before opening the PR.

## Adding a new deep-link handler

`Sources/rtr/DeepLinks.swift` is a list of `DeepLinkHandler`s. Add a new
entry with:

- `name` — what the picker row shows
- `bundleID` — the destination app's bundle identifier
- `matches` — a closure that returns `true` for URLs you want to rewrite
- `rewrite` — produces the custom-scheme URL for the app

Add a test in `Tests/rtrTests/DeepLinksTests.swift` covering the happy
path and at least one URL the handler should ignore.

## Code style

- No new dependencies unless there's a strong reason.
- Prefer pure functions for anything testable.
- Match existing formatting (4-space indent, `final class` by default).
