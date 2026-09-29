# OmaQuote for macOS

Native, menu bar OmaQuote for macOS 26 on Apple Silicon. It shows one quotation on a transparent, click through desktop surface on each display. The selection engine and collection format come from [OmaQuote for Linux](https://github.com/snikulin/omaquote).

## Build and run

Xcode 27 is required. From this checkout:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
Scripts/build-app.sh release
dist/OmaQuote.app/Contents/MacOS/omaquote
```

The `omaquote` command starts the menu bar app. It has no Dock icon. Its popover has the full quote, Previous, Pause/Resume, Next, visibility, reload, config, and quit controls. Left, Space, Right, and Escape work while the popover is open.

The command also accepts `next`, `previous`, `pause`, `resume`, `togglePause`, `show`, `hide`, `toggle`, `reload`, and `status`. A command starts the app if needed; `status` prints JSON.

```sh
dist/OmaQuote.app/Contents/MacOS/omaquote next
dist/OmaQuote.app/Contents/MacOS/omaquote status
```

## Local Homebrew install

This formula uses the local Git checkout. Commit changes before installing; Homebrew builds from committed `main`.

```sh
brew tap snikulin/omaquote-macos /Users/nik/pro/omaquote-macos
brew install snikulin/omaquote-macos/omaquote
omaquote
```

Installation builds the app but does not start it. The formula is tied to this checkout path and intended only for this Mac. There is no GitHub release, login item, or notarized distribution yet.

## Configuration

Edit `~/.config/omarchy/omaquote/config.json` for appearance and behavior. Its schema and defaults match Linux OmaQuote. If the file is absent, the defaults work; the popover's **Config…** action creates and opens a complete template. Put a custom Quote Collection in `~/.config/omarchy/omaquote/quotes.json`. Selection state is written atomically to `~/.local/state/omarchy/omaquote/state.json`.

Changes to config and collection reload automatically. Invalid edits keep the last valid settings or collection, with the error shown in the popover and `omaquote status`.

By default, a file wallpaper URL change advances the quote. Changes across displays during one poll yield one advance. The app checks every five seconds and reestablishes the baseline after wake or display changes. Dynamic and Aerial wallpaper changes without a new file URL cannot be detected; `status` reports `wallpaperDetection: "file-url-only"`. A configured positive interval works independently.

## Source reuse

`Sources/OmaQuoteCore/Resources/JsonDocuments.js` and `QuoteEngine.js` are copied without edits from Linux OmaQuote. The Swift bridge removes the QML only `.pragma library` header at load time. The bundled quote text has separate provenance in [docs/BUNDLED_QUOTES_SOURCES.md](docs/BUNDLED_QUOTES_SOURCES.md).

The app uses AppKit and JavaScriptCore; it has no Quickshell, Qt, Node.js, WebView, or Übersicht dependency. The agreed MVP behavior is recorded in [.scratch/macos-mvp/spec.md](.scratch/macos-mvp/spec.md).

## License

Code is MIT licensed; see [LICENSE](LICENSE). Bundled quote text has separate terms and provenance in [docs/BUNDLED_QUOTES_SOURCES.md](docs/BUNDLED_QUOTES_SOURCES.md).
