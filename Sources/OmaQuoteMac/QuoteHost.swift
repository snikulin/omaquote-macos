import AppKit
import OmaQuoteCore

@MainActor
final class QuoteHost: NSObject {
    private let store: QuoteFileStore
    private let surfaces = QuoteSurfaceManager()
    let wallpaperRotation: WallpaperRotation
    private var runtime: QuoteRuntime!
    private var presentation: PresentationConfiguration!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var popoverController: QuotePopoverController!
    private var inputTimer: Timer?
    private var wallpaperTimer: Timer?
    private var intervalTimer: Timer?
    private var observedConfiguration: String?
    private var observedCollection: String?
    private var wallpaperSignature: String?
    private var hostError: String?
    private var keyboardMonitor: Any?
    private var commandServer: UnixCommandServer?

    init(store: QuoteFileStore = QuoteFileStore()) {
        self.store = store
        wallpaperRotation = WallpaperRotation(stateDirectory: store.stateURL.deletingLastPathComponent())
        super.init()
    }

    func start() throws {
        runtime = try QuoteRuntime()
        let bundled = try QuoteRuntime.bundledCollection()
        var configurationJSON: String?
        var configurationError: String?
        do {
            observedConfiguration = try store.readConfiguration()
            if let text = observedConfiguration {
                try runtime.validateConfiguration(text)
                configurationJSON = text
            }
        } catch {
            configurationError = error.localizedDescription
        }
        var collectionJSON = bundled
        var collectionKind = "bundled"
        var collectionError: String?
        do {
            observedCollection = try store.readUserCollection()
            if let text = observedCollection {
                try runtime.validateCollection(text)
                collectionJSON = text
                collectionKind = "user"
            }
        } catch {
            collectionError = error.localizedDescription
        }
        var stateJSON: String?
        var stateError: String?
        do {
            if let text = try store.readState() {
                try runtime.validateState(text)
                stateJSON = text
            }
        } catch {
            stateError = error.localizedDescription
        }
        let effects = try runtime.initialize(
            collectionJSON: collectionJSON,
            configurationJSON: configurationJSON,
            persistedStateJSON: stateJSON,
            collectionKind: collectionKind,
            collectionError: collectionError,
            configurationError: configurationError,
            stateError: stateError
        )
        try reloadPresentationConfiguration()
        installStatusItem()
        surfaces.onOverflowChanged = { [weak self] overflow in
            guard let self else { return }
            do {
                try self.apply(self.runtime.setPresentationOverflow(overflow))
            } catch { self.showError(error) }
        }
        try apply(effects)
        try rebaselineWallpaper()
        let socketPath = store.stateURL.deletingLastPathComponent().appendingPathComponent("command.sock").path
        commandServer = try UnixCommandServer(path: socketPath) { [weak self] command in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { self?.execute(command) ?? "not-ready" }
            }
        }
        inputTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollInputs() }
        }
        wallpaperTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollWallpaper() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        wallpaperRotation.onStatusChange = { [weak self] in self?.refresh() }
        wallpaperRotation.onWallpaperChanged = { [weak self] in self?.managedWallpaperChanged() }
        wallpaperRotation.start()
    }

    func stop() {
        inputTimer?.invalidate()
        wallpaperTimer?.invalidate()
        wallpaperRotation.stop()
        intervalTimer?.invalidate()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        commandServer?.stop()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func execute(_ command: String) -> String {
        guard runtime != nil else { return "not-ready" }
        do {
            let effects: [QuoteEffect]
            switch command {
            case "next": effects = try runtime.next()
            case "previous": effects = try runtime.previous()
            case "pause": effects = try runtime.pause()
            case "resume": effects = try runtime.resume()
            case "togglePause": effects = try runtime.togglePause()
            case "show": effects = try runtime.setVisibility(true)
            case "hide": effects = try runtime.setVisibility(false)
            case "toggle": effects = try runtime.toggleVisibility()
            case "reload": pollInputs(force: true); return "ok"
            case "status": return try statusJSON()
            default: return "unknown-command"
            }
            try apply(effects)
            return "ok"
        } catch {
            showError(error)
            return "error: \(error.localizedDescription)"
        }
    }

    func openConfiguration() {
        do {
            let raw = try runtime.defaultConfigurationJSON()
            let object = try JSONSerialization.jsonObject(with: Data(raw.utf8))
            let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try store.createConfigurationIfMissing(contents: String(decoding: pretty, as: UTF8.self) + "\n")
            NSWorkspace.shared.open(store.configurationURL)
        } catch { showError(error) }
    }

    func statusJSON() throws -> String {
        var document = try JSONSerialization.jsonObject(with: Data(runtime.statusJSON().utf8)) as? [String: Any] ?? [:]
        document["wallpaperDetection"] = "file-url-only"
        document["wallpaperFolder"] = wallpaperRotation.folderPath
        document["wallpaperIntervalMinutes"] = wallpaperRotation.intervalMinutes
        if let error = wallpaperRotation.error { document["wallpaperRotationError"] = error }
        if let hostError { document["hostError"] = hostError }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "❞"
        statusItem.button?.toolTip = "OmaQuote"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popoverController = QuotePopoverController(host: self)
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = popoverController
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            switch event.keyCode {
            case 123: _ = self.execute("previous")
            case 124: _ = self.execute("next")
            case 49: _ = self.execute("togglePause")
            case 53: self.popover.performClose(nil)
            default: return event
            }
            return nil
        }
    }

    private func apply(_ effects: [QuoteEffect]) throws {
        for effect in effects {
            switch effect {
            case .updatePresentation:
                break
            case .persistState(let text, let recover):
                do {
                    try store.writeState(text)
                    if recover { _ = try runtime.persistenceSucceeded() }
                } catch {
                    _ = try runtime.persistenceFailed(error.localizedDescription)
                }
            case .restartInterval(let minutes):
                intervalTimer?.invalidate()
                intervalTimer = nil
                if minutes > 0 {
                    intervalTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            do { try self.apply(self.runtime.next(source: "interval")) }
                            catch { self.showError(error) }
                        }
                    }
                }
                if minutes > 0 && intervalTimer?.isValid != true {
                    try apply(runtime.intervalFailed("Could not schedule the quote interval"))
                } else {
                    _ = try runtime.intervalSucceeded()
                }
            case .stopInterval:
                intervalTimer?.invalidate()
                intervalTimer = nil
            }
        }
        refresh()
    }

    private func reloadPresentationConfiguration() throws {
        presentation = try JSONDecoder().decode(
            PresentationConfiguration.self, from: Data(runtime.configurationJSON().utf8)
        )
    }

    private func refresh() {
        guard runtime != nil, presentation != nil else { return }
        let status = (try? JSONSerialization.jsonObject(with: Data(runtime.statusJSON().utf8))) as? [String: Any] ?? [:]
        let visible = status["runtimeVisibility"] as? Bool ?? true
        surfaces.update(quote: runtime.currentQuote, configuration: presentation, visible: visible)
        popoverController?.refresh(
            quote: runtime.currentQuote,
            canPrevious: status["canGoPrevious"] as? Bool ?? false,
            paused: status["automaticAdvancePaused"] as? Bool ?? false,
            error: wallpaperRotation.error ?? hostError ?? (status["lastError"] as? String),
            visible: visible
        )
    }

    private func pollInputs(force: Bool = false) {
        hostError = nil
        do {
            let text = try store.readConfiguration()
            if force || text != observedConfiguration {
                observedConfiguration = text
                let effects = try runtime.reloadConfiguration(configurationJSON: text ?? runtime.defaultConfigurationJSON())
                try reloadPresentationConfiguration()
                try apply(effects)
            }
        } catch { showError(error) }
        do {
            let text = try store.readUserCollection()
            if force || text != observedCollection {
                observedCollection = text
                let effects = try runtime.reloadCollection(
                    collectionJSON: text ?? QuoteRuntime.bundledCollection(),
                    kind: text == nil ? "bundled" : "user"
                )
                try apply(effects)
            }
        } catch { showError(error) }
        refresh()
    }

    private func currentWallpaperSignature() -> String? {
        let entries = NSScreen.screens.compactMap { screen -> String? in
            guard let id = QuoteSurfaceManager.displayID(screen),
                  let url = NSWorkspace.shared.desktopImageURL(for: screen), url.isFileURL else { return nil }
            return "\(id):\(url.standardizedFileURL.path)"
        }
        guard entries.count == NSScreen.screens.count, !entries.isEmpty else { return nil }
        return entries.sorted().joined(separator: "\n")
    }

    private func rebaselineWallpaper() throws {
        guard !wallpaperRotation.isApplying else { return }
        if let signature = currentWallpaperSignature() {
            wallpaperSignature = signature
            try apply(runtime.rebaselineWallpaper(pathSignature: signature))
        } else {
            wallpaperSignature = nil
            try apply(runtime.wallpaperUnavailable("A file URL is unavailable for a desktop wallpaper"))
        }
    }

    private func pollWallpaper() {
        guard !wallpaperRotation.isApplying else { return }
        do {
            guard let signature = currentWallpaperSignature() else {
                wallpaperSignature = nil
                try apply(runtime.wallpaperUnavailable("A file URL is unavailable for a desktop wallpaper"))
                return
            }
            if wallpaperSignature == nil {
                try rebaselineWallpaper()
            } else if signature != wallpaperSignature {
                try observeWallpaper(signature)
            }
        } catch { showError(error) }
    }

    private func managedWallpaperChanged() {
        guard let signature = currentWallpaperSignature() else { return }
        do {
            // Rotation already confirmed an actual change, even if the observer missed its previous state.
            try runtime.rebaselineWallpaper(pathSignature: "")
            try observeWallpaper(signature)
        } catch { showError(error) }
    }

    private func observeWallpaper(_ signature: String) throws {
        let effects = try runtime.observeWallpaper(pathSignature: signature)
        wallpaperSignature = signature
        try apply(effects)
    }

    @objc private func screenParametersChanged() {
        surfaces.reconcileScreens()
        do { try rebaselineWallpaper() } catch { showError(error) }
    }

    @objc private func didWake() {
        surfaces.reconcileScreens()
        do { try rebaselineWallpaper() } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        hostError = error.localizedDescription
        refresh()
    }
}
