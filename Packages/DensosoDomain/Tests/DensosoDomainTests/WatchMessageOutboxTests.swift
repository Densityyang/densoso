import XCTest
@testable import DensosoDomain

final class WatchMessageOutboxTests: XCTestCase {
    func testHundredOfflineMessagesRemainOrderedAndDuplicateReplaysDoNotAddRows() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var outbox = WatchMessageOutbox()
        let messages = (0..<100).map { index in
            WatchMessageEnvelope(
                messageID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                createdAt: base.addingTimeInterval(Double(index)),
                payload: .transcript("记录 \(index)")
            )
        }

        for envelope in messages.reversed() {
            XCTAssertTrue(try outbox.enqueue(envelope))
            XCTAssertFalse(try outbox.enqueue(envelope))
        }
        XCTAssertEqual(outbox.pending, messages)

        outbox.acknowledge(messageIDs: Array(messages.prefix(40)).map(\.messageID))
        XCTAssertEqual(outbox.pending, Array(messages.suffix(60)))
    }

    func testMessageIDCannotBeReusedForDifferentPayload() throws {
        let id = UUID()
        var outbox = WatchMessageOutbox()
        XCTAssertTrue(try outbox.enqueue(WatchMessageEnvelope(messageID: id, payload: .transcript("午餐"))))
        XCTAssertThrowsError(try outbox.enqueue(WatchMessageEnvelope(messageID: id, payload: .transcript("晚餐")))) {
            XCTAssertEqual($0 as? WatchMessageError, .messageIDCollision(id))
        }
    }

    func testAcceptedAcknowledgementRemovesMessageAfterPhonePersistsItsReceipt() throws {
        let id = UUID()
        var outbox = WatchMessageOutbox(pending: [
            WatchMessageEnvelope(messageID: id, payload: .transcript("今天跑步"))
        ])
        outbox.acknowledge(.init(messageID: id, state: .accepted))
        XCTAssertTrue(outbox.pending.isEmpty)
    }

    func testCodecRejectsUnsupportedSchemaAndUnboundedTranscript() {
        XCTAssertThrowsError(try WatchMessageCodec.encode(
            WatchMessageEnvelope(schemaVersion: 2, payload: .requestTodaySnapshot)
        )) {
            XCTAssertEqual($0 as? WatchMessageError, .unsupportedSchemaVersion(2))
        }
        XCTAssertThrowsError(try WatchMessageCodec.encode(
            WatchMessageEnvelope(payload: .transcript(String(repeating: "字", count: 4_001)))
        )) {
            XCTAssertEqual($0 as? WatchMessageError, .transcriptTooLong)
        }
    }
}
