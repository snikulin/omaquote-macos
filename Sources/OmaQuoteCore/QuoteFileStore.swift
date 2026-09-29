import Foundation

public struct QuoteFileStore {
    public let configurationURL: URL
    public let collectionURL: URL
    public let stateURL: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let configurationDirectory = homeDirectory
            .appendingPathComponent(".config/omarchy/omaquote", isDirectory: true)
        configurationURL = configurationDirectory.appendingPathComponent("config.json")
        collectionURL = configurationDirectory.appendingPathComponent("quotes.json")
        stateURL = homeDirectory
            .appendingPathComponent(".local/state/omarchy/omaquote", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    public func readConfiguration() throws -> String? { try read(configurationURL) }
    public func readUserCollection() throws -> String? { try read(collectionURL) }
    public func readState() throws -> String? { try read(stateURL) }

    public func writeState(_ contents: String) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: stateURL, options: .atomic)
    }

    public func createConfigurationIfMissing(contents: String) throws {
        try FileManager.default.createDirectory(
            at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try Data(contents.utf8).write(to: configurationURL, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            // Opening the template again must preserve user edits.
        }
    }

    private func read(_ url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }
}
