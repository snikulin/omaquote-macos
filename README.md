# OmaQuote for macOS

OmaQuote for macOS places a quotation on the desktop without changing the wallpaper. It is a native menu bar app for macOS 26 on Apple Silicon, built for people who want the [Linux OmaQuote](https://github.com/snikulin/omaquote) experience on a Mac.

I could not find a macOS counterpart with OmaQuote's combination of a click-through desktop surface, one shared quote across displays, local JSON collections, history, pause, wallpaper-change detection, and automation commands. I built the native macOS app from scratch around the portable JavaScript engine from Linux OmaQuote. The [alternatives research](docs/macos-alternatives.md) explains what was compared; other quote apps do exist.

## Features

- A transparent quote surface behind ordinary windows on every connected display, with no Dock icon.
- A menu bar popover with the full quote, Previous, Pause/Resume, Next, visibility, reload, and config actions.
- A bundled collection of 15 quotes with [documented sources](docs/BUNDLED_QUOTES_SOURCES.md); a local `quotes.json` can replace it.
- A ten-minute interval by default, plus best-effort detection when the file URL of a wallpaper changes.
- The Linux OmaQuote configuration schema, shuffle/history behavior, and CLI commands.

## Install from GitHub with Homebrew

This formula builds the app locally from the public source tag. It requires macOS 26, Apple Silicon, and Xcode 26.6 or later.

```sh
brew tap snikulin/omaquote-macos https://github.com/snikulin/omaquote-macos.git
brew install snikulin/omaquote-macos/omaquote
omaquote
```

Installation does not launch the app. Running `omaquote` starts it; later CLI commands also start it when needed. The app is ad-hoc signed for the local build and is not Developer ID signed or notarized.

## Build from source

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
Scripts/build-app.sh release
dist/OmaQuote.app/Contents/MacOS/OmaQuoteMac --self-test
dist/OmaQuote.app/Contents/MacOS/omaquote
```

The `.app` is written to `dist/`. `swift run OmaQuoteMac` is useful during development, while the bundled app is the supported way to run the desktop UI and bundled font.

## Configuration and collections

The default configuration is in [`default-config.json`](Sources/OmaQuoteCore/Resources/default-config.json). It uses Monaspace Krypton at 20 pixels, white quote text, light gray attribution, a gray backdrop, and a ten-minute interval. The font is included in the app under the [SIL Open Font License](App/Fonts/OFL.txt).

Edit these files to customize the app:

| Path | Purpose |
| --- | --- |
| `~/.config/omarchy/omaquote/config.json` | Appearance and behavior. Omitted fields inherit the bundled defaults. |
| `~/.config/omarchy/omaquote/quotes.json` | Optional collection that replaces the bundled 15 quotes. |
| `~/.local/state/omarchy/omaquote/state.json` | Selection history, written by the app. |

The **Config…** action creates and opens a complete template if `config.json` is absent. File changes reload automatically. An invalid edit leaves the last valid configuration or collection active and reports the error in the popover and `omaquote status`.

Partial configs are checked after they inherit the bundled values. For example, raising `minimumFontSize` above the bundled `preferredFontSize` of 20 also requires setting a higher `preferredFontSize`.

## Command line

```sh
omaquote next
omaquote previous
omaquote pause
omaquote resume
omaquote show
omaquote hide
omaquote reload
omaquote status
```

The command also accepts `togglePause` and `toggle`. `status` prints JSON. Left, Space, Right, and Escape control the popover while it has focus.

## Limits

Wallpaper detection polls file URLs every five seconds. A dynamic or Aerial wallpaper can change without changing its URL; those changes cannot be detected this way. The interval works independently. The current support target is macOS 26 on Apple Silicon; Spaces, Show Desktop, Stage Manager, wake, and multiple-display behavior need broader manual testing on other Macs.

## Development with agents

This macOS project was developed end to end with AI coding agents. Sergey Nikulin set the product goal, requirements, and implementation decisions; agents performed the research, implementation, testing, documentation, and code review. The public source and [agent guide](AGENTS.md) are included so the work can be inspected and continued.

## License and source reuse

The application code is MIT licensed under [LICENSE](LICENSE). `JsonDocuments.js` and `QuoteEngine.js` are copied from Linux OmaQuote and run through JavaScriptCore; the Swift bridge strips their QML-only header at load time. Bundled quote text has [separate provenance](docs/BUNDLED_QUOTES_SOURCES.md). Monaspace Krypton has its [own font license](App/Fonts/OFL.txt).
