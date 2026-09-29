# OmaQuote macOS MVP specification

Status: confirmed by the user on 2026-09-29.
Review baseline: `d2c9a59` on `main`.

## Product

- A native menu-bar-only macOS application for this Apple Silicon Mac running macOS 26. It has no Dock icon or settings window.
- One active Quote appears on transparent, click-through desktop-level Quote Surfaces on every connected display. The surfaces do not take keyboard focus or intercept desktop clicks. Reconnection, waking, Spaces, Show Desktop, and Stage Manager must be checked on this Mac; these events do not themselves advance the Quote.
- A menu bar popover shows the full current Quote, attribution, Previous, Pause/Resume, and Next controls, an error indication, and actions to show/hide the surfaces, reload inputs, open configuration, and quit. Left, Space, Right, and Escape work while the popover has focus.

## Engine and files

- Reuse the unmodified `JsonDocuments.js` and `QuoteEngine.js` through JavaScriptCore. Keep their collection, configuration, history, pause, reload, and validation semantics.
- Execute every engine effect: `update-presentation`, `persist-state`, `restart-interval`, and `stop-interval`. State writes are atomic; write and timer failures are reflected in Runtime Status.
- Use the Linux paths exactly: `~/.config/omarchy/omaquote/config.json`, `~/.config/omarchy/omaquote/quotes.json`, and `~/.local/state/omarchy/omaquote/state.json`.
- Missing configuration uses defaults; missing User Collection uses the bundled collection. The User Collection replaces the bundled one when valid. Input changes reload automatically. On invalid reload, keep the last valid inputs and display the error in the popover and `status`.
- When the configuration file is absent, a menu action creates and opens a complete template without overwriting an existing file. There is no appearance editing UI.

## Presentation

- Preserve the Linux configuration schema and defaults, layout geometry, horizontal alignment, vertical placement, width/height limits, margins, font fitting down to minimum size, ellipsis on overflow, attribution with an em dash at 85% font size, card padding/gap/radius, backdrop opacity, and optional shadow.
- With `fontFamily: null`, use a monospace font. With null colors, use the Linux fallback palette: text `#cacccc`, attribution `#707880`, backdrop `#101315`.

## Automatic advance

- Preserve the Linux defaults: Interval 0 and Wallpaper Change enabled. A positive interval starts a timer; each Advance begins a full new interval. Pause blocks interval and wallpaper advances while preserving manual controls.
- Observe the file URL of the wallpaper on each active screen. Establish a baseline on startup, wake, and display changes. Coalesce a batch of actual URL changes into exactly one Advance. Dynamic/Aerial changes that do not change a file URL cannot be detected reliably; expose the file-URL-only limitation in `status` while the interval remains independent.

## CLI and installation

- A `omaquote` command supports `next`, `previous`, `pause`, `resume`, `togglePause`, `show`, `hide`, `toggle`, `reload`, and `status`. If the app is not running, a command launches it, waits for readiness, and executes once. `status` returns JSON.
- A local Homebrew formula builds the app from this checkout with Xcode and installs the `.app` and command. Installation does not launch the app. GitHub distribution, signing/notarization, and launch at login are outside this MVP.

## Verification and delivery

- Work on `main` and commit the implementation. Run `code-review` on the diff from `d2c9a59` using this specification.
- Use TDD at the public engine/effect, file loading/persistence, and CLI seams. Verify desktop windows manually on this Mac. Run focused tests during implementation and the full suite once at the end.
