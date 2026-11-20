import AppKit
import ImageIO
import OmaQuoteCore

@MainActor
final class WallpaperRotation {
    static let intervals = [0, 5, 10, 15, 30, 60, 120, 240, 1440]
    private static let defaultInterval = 10
    private static let folderKey = "WallpaperFolder"
    private static let intervalKey = "WallpaperIntervalMinutes"

    private let defaults: UserDefaults
    private let store: WallpaperStore
    private let home: URL
    private var timer: Timer?
    private var running = false
    private var pendingFolderChange = false
    private(set) var isApplying = false
    private(set) var error: String?
    var onStatusChange: (() -> Void)?
    var onWallpaperChanged: (() -> Void)?

    init(stateDirectory: URL, defaults: UserDefaults = .standard,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.home = home
        store = WallpaperStore(
            url: home.appending(path: "Library/Application Support/com.apple.wallpaper/Store/Index.plist"),
            backupURL: stateDirectory.appending(path: "wallpaper-index-backup.plist")
        )
        defaults.register(defaults: [
            Self.folderKey: "~/wallpapers",
            Self.intervalKey: Self.defaultInterval
        ])
    }

    var folderPath: String { defaults.string(forKey: Self.folderKey) ?? "~/wallpapers" }

    var folder: URL {
        if folderPath.hasPrefix("~/") {
            return home.appending(path: String(folderPath.dropFirst(2)), directoryHint: .isDirectory)
        }
        return URL(filePath: folderPath, directoryHint: .isDirectory)
    }

    var intervalMinutes: Int {
        let interval = defaults.integer(forKey: Self.intervalKey)
        return Self.intervals.contains(interval) ? interval : Self.defaultInterval
    }

    func start() {
        running = true
        if intervalMinutes > 0 { next() }
    }

    func stop() {
        running = false
        timer?.invalidate()
    }

    func setFolder(_ url: URL) {
        defaults.set(url.path(percentEncoded: false), forKey: Self.folderKey)
        error = nil
        if intervalMinutes > 0 {
            if isApplying { pendingFolderChange = true } else { next() }
        }
        onStatusChange?()
    }

    func setInterval(_ minutes: Int) {
        let wasOff = intervalMinutes == 0
        defaults.set(minutes, forKey: Self.intervalKey)
        if intervalMinutes == 0 { error = nil }
        if wasOff && intervalMinutes > 0 {
            next()
        } else {
            schedule()
        }
        onStatusChange?()
    }

    func next() {
        guard running, !isApplying else { return }
        timer?.invalidate()
        isApplying = true
        error = nil
        onStatusChange?()

        let directory = folder
        let current = Set(Self.activeImages().compactMap { $0 })
        Task {
            defer {
                isApplying = false
                let rotateAgain = pendingFolderChange && intervalMinutes > 0 && running
                pendingFolderChange = false
                if rotateAgain {
                    next()
                } else {
                    schedule()
                    onStatusChange?()
                }
            }
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try Self.selectImage(in: directory, avoiding: current)
                }.value
                guard running else { return }
                if try await apply(image) { onWallpaperChanged?() }
            } catch {
                self.error = "Wallpaper: \(error.localizedDescription)"
            }
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard running, intervalMinutes > 0 else { return }
        let timer = Timer(timeInterval: TimeInterval(intervalMinutes) * 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func apply(_ image: URL) async throws -> Bool {
        let activeBefore = Self.activeImages()
        if Self.allUse(image, images: activeBefore), try store.configuredImage() == image { return false }

        let change = try store.apply(image: image)
        do {
            try Self.reloadAgent()
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(200))
                if Self.allUse(image, images: Self.activeImages()), try store.configuredImage() == image {
                    return !Self.allUse(image, images: activeBefore)
                }
            }
            throw Failure.unconfirmed
        } catch {
            if (try? store.rollback(change)) == true { try? Self.reloadAgent() }
            throw error
        }
    }

    private static func activeImages() -> [URL?] {
        NSScreen.screens.map { screen in
            NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    private static func allUse(_ target: URL, images: [URL?]) -> Bool {
        !images.isEmpty && images.allSatisfy { $0 == target }
    }

    private static func reloadAgent() throws {
        // Address only the wallpaper service in this GUI login session.
        for agent in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.wallpaper.agent")
        where !agent.isTerminated {
            guard kill(agent.processIdentifier, SIGTERM) == 0 || errno == ESRCH else {
                throw Failure.reloadFailed
            }
        }
    }

    nonisolated private static func selectImage(in folder: URL, avoiding current: Set<URL>) throws -> URL {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ).shuffled()
        var fallback: URL?
        for entry in entries {
            let file = entry.standardizedFileURL.resolvingSymlinksInPath()
            guard (try? file.resourceValues(forKeys: keys).isRegularFile) == true,
                  let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 64
                  ] as CFDictionary) != nil else { continue }
            if !current.contains(file) { return file }
            fallback = file
        }
        if let fallback { return fallback }
        throw Failure.emptyFolder(folder.lastPathComponent)
    }

    private enum Failure: LocalizedError {
        case emptyFolder(String)
        case reloadFailed
        case unconfirmed

        var errorDescription: String? {
            switch self {
            case .emptyFolder(let folder): "No readable images in “\(folder)”."
            case .reloadFailed: "Could not reload the macOS wallpaper service."
            case .unconfirmed: "macOS did not confirm the new wallpaper."
            }
        }
    }
}
