import Foundation
import XCTest
@testable import OmaQuoteCore

final class WallpaperStoreTests: XCTestCase {
    func testGlobalWallpaperPreservesOriginalSettingsAndCanBeRolledBack() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WallpaperStore(
            url: directory.appending(path: "Index.plist"),
            backupURL: directory.appending(path: "backup.plist")
        )
        let linked = ["Content": ["Shuffle": "$null"]]
        let root: [String: Any] = [
            "AllSpacesAndDisplays": ["Type": "linked", "Linked": linked],
            "SystemDefault": ["Type": "desktop"],
            "Spaces": ["test-space": ["Type": "idle"]],
            "Displays": ["test-display": ["Type": "desktop"]]
        ]
        let original = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try original.write(to: store.url)
        let image = directory.appending(path: "Обои #1.jpg")
        let change = try store.apply(image: image)
        XCTAssertEqual(try store.configuredImage(), image)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), original)

        let updatedData = try Data(contentsOf: store.url)
        let updated = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: updatedData, format: nil) as? [String: Any]
        )
        let global = try XCTUnwrap(updated["AllSpacesAndDisplays"] as? [String: Any])
        XCTAssertEqual(global["Type"] as? String, "individual")
        XCTAssertEqual(global["Idle"] as? [String: [String: String]], linked)
        for scope in ["SystemDefault", "Spaces", "Displays"] {
            XCTAssertEqual(updated[scope] as? NSDictionary, root[scope] as? NSDictionary)
        }
        XCTAssertTrue(try store.rollback(change))
        XCTAssertEqual(try Data(contentsOf: store.url), original)

        let nextChange = try store.apply(image: image)
        try original.write(to: store.url)
        XCTAssertFalse(try store.rollback(nextChange))
        XCTAssertEqual(try Data(contentsOf: store.backupURL), original)
    }

    func testNullGlobalScopeCanBeSetAndUnknownSchemaIsRejected() throws {
        var root: [String: Any] = [
            "AllSpacesAndDisplays": "$null",
            "SystemDefault": ["Type": "desktop"],
            "Spaces": [:],
            "Displays": [:]
        ]
        let image = URL(filePath: "/tmp/wallpaper.jpg")
        let original = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let data = try WallpaperStore.replacingWallpaper(in: original, with: image, date: Date())
        let updated = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual((updated["AllSpacesAndDisplays"] as? [String: Any])?["Type"] as? String, "desktop")

        root["AllSpacesAndDisplays"] = ["Type": "unknown"]
        let unsupported = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        XCTAssertThrowsError(try WallpaperStore.replacingWallpaper(in: unsupported, with: image, date: Date()))
    }
}
