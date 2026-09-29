import Foundation
import XCTest
@testable import OmaQuoteCore

final class UnixCommandChannelTests: XCTestCase {
    func testClientReceivesResponseFromRunningHost() throws {
        let path = "/tmp/omaquote-test-\(UUID().uuidString.prefix(12)).sock"
        let server = try UnixCommandServer(path: path) { command in "received:\(command)" }
        defer { server.stop() }

        XCTAssertEqual(try UnixCommandClient.send("status", to: path), "received:status")
        XCTAssertEqual(try UnixCommandClient.send("next", to: path), "received:next")
    }
}
