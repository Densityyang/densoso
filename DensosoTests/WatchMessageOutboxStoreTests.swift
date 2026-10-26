import Foundation
import XCTest
@testable import Densoso

@MainActor
final class WatchMessageOutboxStoreTests: XCTestCase {
    func testPendingCommandsAndCausalSequenceSurviveStoreRecreation() throws {
        let suiteName = "WatchMessageOutboxStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = WatchMessageOutboxStore(defaults: defaults)
        var outbox = try firstStore.load()
        let first = try outbox.enqueueCausalCommand(.confirm(actionID: UUID()))
        try firstStore.save(outbox)

        let restoredStore = WatchMessageOutboxStore(defaults: defaults)
        var restored = try restoredStore.load()
        XCTAssertEqual(restored.pending, [first])
        XCTAssertEqual(restored.latestCausalSequence, 1)

        restored.acknowledge(.init(messageID: first.messageID, state: .processed))
        try restoredStore.save(restored)
        XCTAssertTrue(try WatchMessageOutboxStore(defaults: defaults).load().pending.isEmpty)
    }

    func testCorruptPersistedOutboxIsNotSilentlyReplacedByAnEmptyQueue() throws {
        let suiteName = "WatchMessageOutboxStoreCorruptTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("invalid outbox".utf8), forKey: WatchMessageOutboxStore.storageKey)

        XCTAssertThrowsError(try WatchMessageOutboxStore(defaults: defaults).load())
    }
}
