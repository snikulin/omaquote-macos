import Foundation

/// The per-user WallpaperAgent store on macOS 26.
public struct WallpaperStore: Sendable {
    public let url: URL
    public let backupURL: URL

    public init(url: URL, backupURL: URL) {
        self.url = url
        self.backupURL = backupURL
    }

    public struct Change {
        fileprivate let original: Data
        fileprivate let updated: Data
    }

    public func apply(image: URL) throws -> Change {
        let original = try Data(contentsOf: url)
        let updated = try Self.replacingWallpaper(in: original, with: image, date: Date())
        try FileManager.default.createDirectory(
            at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try original.write(to: backupURL, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            // Keep the settings from before the first rotation.
        }
        guard try Data(contentsOf: url) == original else { throw Failure.concurrentChange }
        try updated.write(to: url, options: .atomic)
        return Change(original: original, updated: updated)
    }

    /// Roll back a failed reload only while the store still contains our write.
    public func rollback(_ change: Change) throws -> Bool {
        guard try Data(contentsOf: url) == change.updated else { return false }
        try change.original.write(to: url, options: .atomic)
        return true
    }

    public func configuredImage() throws -> URL? {
        let data = try Data(contentsOf: url)
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let global = root["AllSpacesAndDisplays"] as? [String: Any],
              let type = global["Type"] as? String, type == "desktop" || type == "individual",
              let desktop = global["Desktop"] as? [String: Any],
              let content = desktop["Content"] as? [String: Any],
              content["Shuffle"] as? String == "$null",
              let choices = content["Choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first, choice["Provider"] as? String == "com.apple.wallpaper.choice.image",
              let configuration = choice["Configuration"] as? Data,
              let image = try PropertyListSerialization.propertyList(from: configuration, format: nil) as? [String: Any],
              image["type"] as? String == "imageFile",
              let encodedURL = image["url"] as? [String: Any],
              let relative = encodedURL["relative"] as? String,
              let url = URL(string: relative), url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    static func replacingWallpaper(in data: Data, with image: URL, date: Date) throws -> Data {
        guard var root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              root["SystemDefault"] is [String: Any],
              root["Spaces"] is [String: Any],
              root["Displays"] is [String: Any] else { throw Failure.unsupportedStore }

        var global: [String: Any]
        switch root["AllSpacesAndDisplays"] {
        case let entry as [String: Any]:
            global = entry
            switch global["Type"] as? String {
            case "desktop", "idle", "individual":
                break
            case "linked":
                guard let linked = global.removeValue(forKey: "Linked") as? [String: Any] else {
                    throw Failure.unsupportedStore
                }
                // Preserve the old linked choice as the independent screen saver.
                global["Idle"] = linked
            default:
                throw Failure.unsupportedStore
            }
        case let marker as String where marker == "$null":
            global = [:]
        default:
            throw Failure.unsupportedStore
        }

        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["type": "imageFile", "url": ["relative": image.absoluteString]],
            format: .binary, options: 0
        )
        let choice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.image",
            "Configuration": configuration,
            "Files": []
        ]
        global["Desktop"] = [
            "Content": ["Choices": [choice], "EncodedOptionValues": "$null", "Shuffle": "$null"],
            "LastSet": date,
            "LastUse": date
        ]
        global["Type"] = global["Idle"] is [String: Any] ? "individual" : "desktop"
        root["AllSpacesAndDisplays"] = global
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    private enum Failure: LocalizedError {
        case unsupportedStore
        case concurrentChange

        var errorDescription: String? {
            switch self {
            case .unsupportedStore: "This macOS wallpaper settings format is unsupported."
            case .concurrentChange: "Wallpaper settings changed during rotation. Try again."
            }
        }
    }
}
