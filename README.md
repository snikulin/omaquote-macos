# OmaQuote for macOS

Native macOS project for a desktop Quote Surface inspired by [OmaQuote](https://github.com/snikulin/omaquote). This repository currently contains a **working core integration spike**, not a finished desktop app. `swift run OmaQuoteMac` validates the bundled Quote Collection, selects a Quote through the existing OmaQuote engine, and prints its Runtime Status. It does not yet draw on the desktop.

## Development

Requirements: macOS 15 or later and Swift 6.3 Command Line Tools. The eventual `.app` bundle will require Xcode for GUI debugging and packaging.

```sh
swift build
swift run OmaQuoteMac --self-test
swift run OmaQuoteMac
```

The self-test checks that the original JavaScript engine runs in JavaScriptCore, the bundled collection validates, Presentation History and Automatic Advance Pause behave as expected, and duplicate JSON keys are rejected. The installed Command Line Tools on the initial development machine lack both `Testing` and `XCTest`, so this smoke test is part of the executable for now.

## Reuse boundary

- `Sources/OmaQuoteCore/Resources/JsonDocuments.js` and `QuoteEngine.js` are copied without edits from OmaQuote. The Swift bridge strips the QML-only `.pragma library` line at load time.
- `Sources/OmaQuoteCore/Resources/quotes.json` is the bundled OmaQuote collection. Its text has separate provenance recorded in [docs/BUNDLED_QUOTES_SOURCES.md](docs/BUNDLED_QUOTES_SOURCES.md); the MIT code license does not automatically cover the quotations.
- `QuoteRuntime.swift` is a small, single-threaded JavaScriptCore adapter. It currently exposes initialization, manual Advance, Backward Navigation, pause/resume, and status. It does **not** yet execute the engine's returned effects, so there is no persistence, Interval, collection reload, or wallpaper observation.
- No Quickshell, Qt, Node.js, WebView, or Übersicht dependency is needed.

The macOS application will supply a transparent, click-through Quote Surface on each display and native Quote Controls. Platform integration should keep the existing engine's semantics and use the [domain vocabulary](https://github.com/snikulin/omaquote/blob/main/CONTEXT.md). See [macOS alternatives research](docs/macos-alternatives.md) for technical constraints and source links.

## Next implementation steps

1. Validate desktop-level transparent windows across Spaces, Show Desktop, Stage Manager, and multiple displays.
2. Execute `update-presentation`, `persist-state`, `restart-interval`, and `stop-interval` effects in the Swift host.
3. Add menu-bar Quote Controls, User Collection loading, atomic state writes, and configuration reload.
4. Add optional best-effort Wallpaper Change detection after the basic Interval and manual controls work.

## License

Code is MIT licensed; see [LICENSE](LICENSE). Bundled Quote text has separate terms and provenance in [docs/BUNDLED_QUOTES_SOURCES.md](docs/BUNDLED_QUOTES_SOURCES.md).
