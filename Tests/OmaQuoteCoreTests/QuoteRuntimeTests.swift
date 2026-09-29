import XCTest
@testable import OmaQuoteCore

final class QuoteRuntimeTests: XCTestCase {
    private let collection = """
        {"version":1,"quotes":[{"text":"First"},{"text":"Second"}]}
        """

    func testBundledContentUsesVerifiedCollectionAndDefaultConfiguration() throws {
        let document = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(QuoteRuntime.bundledCollection().utf8)
        ) as? [String: Any])
        let quotes = try XCTUnwrap(document["quotes"] as? [[String: String]])
        XCTAssertEqual(quotes.count, 15)
        XCTAssertEqual(quotes.first?["attribution"], "Ralph Waldo Emerson")

        let runtime = try QuoteRuntime()
        try runtime.initialize(collectionJSON: collection, randomValues: [0, 0])
        let defaults = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(runtime.configurationJSON().utf8)
        ) as? [String: Any])
        XCTAssertEqual(defaults["intervalMinutes"] as? Int, 10)
        XCTAssertEqual(defaults["fontFamily"] as? String, "Monaspace Krypton")
        XCTAssertEqual(defaults["preferredFontSize"] as? Int, 20)
        XCTAssertEqual(defaults["textColor"] as? String, "#FFFFFF")
        XCTAssertEqual(defaults["attributionColor"] as? String, "#D9D9D9")
        XCTAssertEqual(defaults["backdropColor"] as? String, "#505050")
    }

    func testPartialUserConfigurationOverridesBundledDefaults() throws {
        let runtime = try QuoteRuntime()
        try runtime.initialize(
            collectionJSON: collection,
            configurationJSON: #"{"version":1,"shadow":true}"#,
            randomValues: [0, 0]
        )
        let effective = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(runtime.configurationJSON().utf8)
        ) as? [String: Any])
        XCTAssertEqual(effective["intervalMinutes"] as? Int, 10)
        XCTAssertEqual(effective["fontFamily"] as? String, "Monaspace Krypton")
        XCTAssertEqual(effective["shadow"] as? Bool, true)
    }

    func testPartialFontOverrideMustFitBundledPreferredSize() throws {
        let runtime = try QuoteRuntime()
        XCTAssertThrowsError(try runtime.validateConfiguration(
            #"{"version":1,"minimumFontSize":22}"#
        ))
        XCTAssertNoThrow(try runtime.validateConfiguration(
            #"{"version":1,"preferredFontSize":24,"minimumFontSize":22}"#
        ))
    }

    func testSelectionAndPauseReturnEffectsForTheHost() throws {
        let runtime = try QuoteRuntime()

        let initial = try runtime.initialize(collectionJSON: collection, randomValues: [0, 0])
        XCTAssertEqual(initial.map(\.kind), [.updatePresentation, .persistState, .restartInterval])

        let advanced = try runtime.next(randomValues: [0, 0])
        XCTAssertEqual(advanced.map(\.kind), [.updatePresentation, .persistState, .restartInterval])

        let paused = try runtime.pause()
        XCTAssertEqual(paused.map(\.kind), [.stopInterval])
    }

    func testConfigurationAndPersistedSelectionSurviveRestart() throws {
        let configuration = """
            {"version":1,"selectionMode":"random","intervalMinutes":2}
            """
        let first = try QuoteRuntime()
        let effects = try first.initialize(
            collectionJSON: collection,
            configurationJSON: configuration,
            randomValues: [0]
        )
        XCTAssertEqual(effects.map(\.kind), [.updatePresentation, .persistState, .restartInterval])
        let state = try XCTUnwrap(effects.compactMap { effect -> String? in
            if case .persistState(let json, _) = effect { return json }
            return nil
        }.first)

        let restored = try QuoteRuntime()
        let restoredEffects = try restored.initialize(
            collectionJSON: collection,
            configurationJSON: configuration,
            persistedStateJSON: state,
            randomValues: [0.99]
        )
        XCTAssertEqual(restored.currentQuote, first.currentQuote)
        XCTAssertEqual(restoredEffects.map(\.kind), [.updatePresentation, .restartInterval])
    }

    func testInvalidCollectionReloadKeepsLastGoodQuoteAndReportsError() throws {
        let runtime = try QuoteRuntime()
        try runtime.initialize(collectionJSON: collection, randomValues: [0, 0])
        let original = runtime.currentQuote

        let effects = try runtime.reloadCollection(collectionJSON: "{bad json")
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(runtime.currentQuote, original)
        let failedStatus = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(runtime.statusJSON().utf8)
        ) as? [String: Any])
        XCTAssertNotNil(failedStatus["lastError"] as? String)

        try runtime.reloadCollection(collectionJSON: collection)
        XCTAssertEqual(runtime.currentQuote, original)
        let recoveredStatus = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(runtime.statusJSON().utf8)
        ) as? [String: Any])
        XCTAssertTrue(recoveredStatus["lastError"] is NSNull)
    }

    func testCollectionReloadUsesProvidedRandomSelection() throws {
        let runtime = try QuoteRuntime()
        try runtime.initialize(
            collectionJSON: collection,
            configurationJSON: #"{"version":1,"selectionMode":"random"}"#,
            randomValues: [0]
        )
        try runtime.reloadCollection(collectionJSON: """
            {"version":1,"quotes":[{"text":"New A"},{"text":"New B"},{"text":"New C"}]}
            """, randomValues: [0.99])
        XCTAssertEqual(runtime.currentQuote?.text, "New C")
    }

    func testConfigurationReloadRestartsIntervalAndRejectsInvalidUpdate() throws {
        let runtime = try QuoteRuntime()
        try runtime.initialize(collectionJSON: collection, randomValues: [0, 0])

        let effects = try runtime.reloadConfiguration(configurationJSON: """
            {"version":1,"intervalMinutes":3}
            """)
        XCTAssertEqual(effects.map(\.kind), [.restartInterval])
        XCTAssertTrue(try runtime.statusJSON().contains("\"intervalMinutes\":3"))

        let rejected = try runtime.reloadConfiguration(configurationJSON: """
            {"version":1,"intervalMinutes":-1}
            """)
        XCTAssertTrue(rejected.isEmpty)
        XCTAssertTrue(try runtime.statusJSON().contains("\"intervalMinutes\":3"))
        XCTAssertFalse(try runtime.statusJSON().contains("\"lastError\":null"))
    }

    func testWallpaperBaselineAndPauseDoNotQueueMissedAdvances() throws {
        let runtime = try QuoteRuntime()
        try runtime.initialize(collectionJSON: collection, randomValues: [0, 0])
        let first = runtime.currentQuote
        XCTAssertTrue(try runtime.observeWallpaper(pathSignature: "display:A").isEmpty)
        try runtime.observeWallpaper(pathSignature: "display:B")
        let second = runtime.currentQuote
        XCTAssertNotEqual(first, second)

        try runtime.pause()
        XCTAssertTrue(try runtime.observeWallpaper(pathSignature: "display:C").isEmpty)
        XCTAssertEqual(runtime.currentQuote, second)
        try runtime.resume()
        XCTAssertTrue(try runtime.observeWallpaper(pathSignature: "display:C").isEmpty)
        XCTAssertEqual(runtime.currentQuote, second)
        XCTAssertTrue(try runtime.rebaselineWallpaper(pathSignature: "display:D").isEmpty)
        XCTAssertEqual(runtime.currentQuote, second)
    }

    func testStartupFallbackReportsInvalidUserCollection() throws {
        let runtime = try QuoteRuntime()
        try runtime.initialize(
            collectionJSON: collection,
            collectionError: "User Collection is invalid",
            randomValues: [0, 0]
        )
        XCTAssertEqual(runtime.currentQuote != nil, true)
        XCTAssertTrue(try runtime.statusJSON().contains("User Collection is invalid"))
    }
}
