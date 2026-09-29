# Agent guide

OmaQuote for macOS is a native AppKit menu bar application. It displays one
active quote on transparent desktop-level windows across displays. The Swift
host runs the shared Linux OmaQuote JavaScript engine through JavaScriptCore.

## Project map

- `Sources/OmaQuoteCore/Resources/JsonDocuments.js` and `QuoteEngine.js` are
  copied from Linux OmaQuote. Keep their validation and transition semantics
  aligned with upstream; document intentional divergence and test it.
- `QuoteRuntime.swift` bridges JavaScript values and effects. The bundled
  `default-config.json` supplies macOS defaults; user config fields override
  it. Validate the effective merged config, including font-size ranges; this
  can reject a partial config that upstream Linux accepts against its own
  defaults. `quotes.json` is the public 15-quote collection.
- `QuoteHost.swift` applies effects and coordinates files, wallpaper polling,
  the timer, menu bar UI, CLI socket, and desktop surfaces.
- `App/Info.plist`, `App/Fonts`, and `Scripts/build-app.sh` assemble the `.app`.
  `Formula/omaquote.rb` builds that app from the public Git tag.

## Local workflow

Use Xcode 26.6 or later on macOS 26. Set `DEVELOPER_DIR` to
`/Applications/Xcode.app/Contents/Developer` if `xcode-select` points at
Command Line Tools.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
Scripts/build-app.sh release
dist/OmaQuote.app/Contents/MacOS/OmaQuoteMac --self-test
```

Test engine effects, configuration and collection validation, file behavior,
and CLI transport with focused tests. Run the full test suite before delivery.
Manually check the menu bar popover and desktop windows on supported macOS,
including Spaces, Show Desktop, wake, and multiple displays when available.

## Compatibility and distribution

- Preserve the Linux JSON schema and user paths under
  `~/.config/omarchy/omaquote/`; state belongs under
  `~/.local/state/omarchy/omaquote/`.
- Keep the personal 119-quote collection out of this public repository and
  its Git history. It belongs in a user's local `quotes.json` only. The
  bundled 15 quotes have sources recorded in
  `docs/BUNDLED_QUOTES_SOURCES.md`.
- The code is MIT licensed. The quote text has separate provenance. The
  Monaspace font is under the license in `App/Fonts/OFL.txt`.
- When releasing, update the version in `App/Info.plist` and
  `Formula/omaquote.rb` together, then tag the exact source commit. Verify
  the Homebrew install and CLI auto-launch from that tag before announcing it.
