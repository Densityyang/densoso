import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class WatchMessageInboxStoreTests: XCTestCase {
    func testRepeatedOfflineTranscriptReplayCreatesOneDurableInboxMessage() throws {
        let store = try makeStore()
        let envelope = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!,
            payload: .transcript("记录午餐")
        )

        XCTAssertEqual(try store.ingest(envelope), .accepted)
        for _ in 0..<100 {
            XCTAssertEqual(try store.ingest(envelope), .duplicatePending)
        }
        XCTAssertEqual(try store.receiptCount(), 1)
        XCTAssertEqual(try store.inboxMessageCount(), 1)
        XCTAssertEqual(try store.pendingTranscripts().map(\.text), ["记录午餐"])

        try store.setState(WatchReceiptState.processed, for: envelope.messageID)
        XCTAssertEqual(try store.ingest(envelope), .duplicateProcessed)
        XCTAssertTrue(try store.pendingTranscripts().isEmpty)
        XCTAssertEqual(try store.recentProcessedMessageIDs(), [envelope.messageID])
    }

    func testOutOfOrderMessagesAreReturnedInDurableArrivalOrder() throws {
        let store = try makeStore()
        let older = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
            createdAt: Date(timeIntervalSince1970: 10),
            payload: .transcript("第一条")
        )
        let newer = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000703")!,
            createdAt: Date(timeIntervalSince1970: 20),
            payload: .transcript("第二条")
        )
        XCTAssertEqual(try store.ingest(newer), .accepted)
        XCTAssertEqual(try store.ingest(older), .accepted)
        XCTAssertEqual(try store.pendingTranscripts().map(\.text), ["第二条", "第一条"])
    }

    func testConflictingPayloadWithSameMessageIDIsRejected() throws {
        let store = try makeStore()
        let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000704")!
        XCTAssertEqual(try store.ingest(WatchMessageEnvelope(messageID: messageID, payload: .transcript("步行"))), .accepted)
        XCTAssertEqual(try store.ingest(WatchMessageEnvelope(messageID: messageID, payload: .transcript("跑步"))), .payloadConflict)
        XCTAssertEqual(try store.receiptCount(), 1)
        XCTAssertEqual(try store.inboxMessageCount(), 1)
    }

    private func makeStore() throws -> WatchMessageInboxStore {
        let schema = Schema(versionedSchema: DensosoSchemaV3.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return WatchMessageInboxStore(modelContainer: container)
    }
}
