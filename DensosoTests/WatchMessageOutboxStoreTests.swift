import Foundation
import XCTest
@testable import Densoso

@MainActor
final class WatchMessageOutboxStoreTests: XCTestCase {
    func testPendingCommandsAndCausalSequenceSurviveStoreRecreation() throws {
        let suiteName = "WatchMessageOutboxStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let firstStore = try WatchMessageOutboxStore(defaults: defaults, directoryURL: directoryURL)
        var outbox = try firstStore.load()
        let first = try outbox.enqueueCausalCommand(.confirm(actionID: UUID()))
        try firstStore.save(outbox)

        let restoredStore = try WatchMessageOutboxStore(defaults: defaults, directoryURL: directoryURL)
        var restored = try restoredStore.load()
        XCTAssertEqual(restored.pending, [first])
        XCTAssertEqual(restored.latestCausalSequence, 1)

        restored.acknowledge(.init(messageID: first.messageID, state: .processed))
        try restoredStore.save(restored)
        XCTAssertTrue(try WatchMessageOutboxStore(defaults: defaults, directoryURL: directoryURL).load().pending.isEmpty)
    }

    func testLegacyDefaultsOutboxMigratesToDurableFile() throws {
        let suiteName = "WatchMessageOutboxStoreMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directoryURL)
        }

        var legacyOutbox = WatchMessageOutbox()
        let pending = try legacyOutbox.enqueueCausalCommand(.transcript("恢复离线记录"))
        defaults.set(try JSONEncoder().encode(legacyOutbox), forKey: WatchMessageOutboxStore.legacyStorageKey)

        let store = try WatchMessageOutboxStore(defaults: defaults, directoryURL: directoryURL)
        XCTAssertEqual(try store.load().pending, [pending])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.storageURL.path))
        XCTAssertNil(defaults.data(forKey: WatchMessageOutboxStore.legacyStorageKey))
    }

    func testCorruptPersistedFileIsNotSilentlyReplacedByAnEmptyQueue() throws {
        let suiteName = "WatchMessageOutboxStoreCorruptTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let storageURL = directoryURL.appendingPathComponent(WatchMessageOutboxStore.storageFileName)
        try Data("invalid outbox".utf8).write(to: storageURL)

        XCTAssertThrowsError(try WatchMessageOutboxStore(defaults: defaults, directoryURL: directoryURL).load())
    }

    func testFileWriteFailureIsReportedToStopDispatch() throws {
        let suiteName = "WatchMessageOutboxStoreWriteFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let blockedDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: blockedDirectoryURL)
        }
        try Data("file blocks directory creation".utf8).write(to: blockedDirectoryURL)

        let store = try WatchMessageOutboxStore(defaults: defaults, directoryURL: blockedDirectoryURL)
        var outbox = WatchMessageOutbox()
        _ = try outbox.enqueueCausalCommand(.confirm(actionID: UUID()))

        XCTAssertThrowsError(try store.save(outbox))
    }
}
