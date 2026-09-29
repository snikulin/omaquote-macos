import Foundation
import XCTest
@testable import OmaQuoteCore

final class QuoteFileStoreTests: XCTestCase {
    func testConfigurationTemplateIsCreatedOnceAndStateIsSaved() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = QuoteFileStore(homeDirectory: home)

        XCTAssertNil(try store.readConfiguration())
        let template = """
            {"version":1,"intervalMinutes":0}
            """
        try store.createConfigurationIfMissing(contents: template)
        XCTAssertEqual(try store.readConfiguration(), template)
        try store.createConfigurationIfMissing(contents: "replacement")
        XCTAssertEqual(try store.readConfiguration(), template)

        try store.writeState("{\"version\":1}\n")
        XCTAssertEqual(try store.readState(), "{\"version\":1}\n")
        XCTAssertTrue(store.stateURL.path.hasSuffix("/.local/state/omarchy/omaquote/state.json"))
    }
}
