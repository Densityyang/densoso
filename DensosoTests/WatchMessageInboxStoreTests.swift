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

    func testPhoneAcknowledgesDurablePendingReceiptBeforeTranscriptProcessing() throws {
        let store = try makeStore()
        let envelope = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000705")!,
            payload: .transcript("午餐记录")
        )

        XCTAssertEqual(try store.ingest(envelope), .accepted)
        XCTAssertEqual(try store.recentReceivedMessageIDs(), [envelope.messageID])
        XCTAssertEqual(try store.pendingTranscripts().map(\.messageID), [envelope.messageID])
    }

    func testPendingCommandReplayReturnsOnlyNonTranscriptEnvelopesInArrivalOrder() throws {
        let store = try makeStore()
        let transcript = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000706")!,
            payload: .transcript("记录午餐")
        )
        let confirm = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000707")!,
            payload: .confirm(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000717")!)
        )
        let reject = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000708")!,
            payload: .reject(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000718")!)
        )

        for envelope in [transcript, confirm, reject] {
            XCTAssertEqual(try store.ingest(envelope), .accepted)
        }

        let pendingCommands = try store.pendingCommandEnvelopes()
        XCTAssertEqual(pendingCommands.map(\.messageID), [confirm.messageID, reject.messageID])
        XCTAssertEqual(pendingCommands.map(\.payload), [confirm.payload, reject.payload])
        XCTAssertEqual(try store.pendingTranscripts().map(\.messageID), [transcript.messageID])
    }

    func testCausalReplayWaitsForMissingAndPendingPredecessorThenOrdersBySequence() throws {
        let store = try makeStore()
        let predecessor = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000721")!,
            causalSequence: 1,
            payload: .confirm(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000731")!)
        )
        let successor = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000722")!,
            causalSequence: 2,
            dependsOn: 1,
            payload: .reject(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000732")!)
        )

        XCTAssertEqual(try store.ingest(successor), .accepted)
        XCTAssertEqual(
            WatchCommandDependencyPolicy.decision(
                for: successor,
                sequenceStates: try store.causalSequenceStates()
            ),
            .waitingFor(1)
        )
        XCTAssertEqual(try store.ingest(predecessor), .accepted)
        XCTAssertEqual(try store.pendingReplayEnvelopes().map(\.messageID), [predecessor.messageID, successor.messageID])
        XCTAssertFalse(try store.hasEarlierPendingCommand(before: predecessor.messageID))
        XCTAssertFalse(try store.hasEarlierPendingCommand(before: successor.messageID))

        try store.setState(WatchReceiptState.processed, for: predecessor.messageID)
        XCTAssertEqual(
            WatchCommandDependencyPolicy.decision(
                for: successor,
                sequenceStates: try store.causalSequenceStates()
            ),
            .ready
        )
    }

    func testRejectedAndConflictingPredecessorsRejectCausalSuccessors() throws {
        let store = try makeStore()
        let predecessor = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000723")!,
            causalSequence: 1,
            payload: .confirm(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000733")!)
        )
        let successor = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000724")!,
            causalSequence: 2,
            dependsOn: 1,
            payload: .reject(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000734")!)
        )
        XCTAssertEqual(try store.ingest(predecessor), .accepted)
        XCTAssertEqual(try store.ingest(successor), .accepted)
        try store.setState(WatchReceiptState.rejected, for: predecessor.messageID)
        XCTAssertEqual(
            WatchCommandDependencyPolicy.decision(
                for: successor,
                sequenceStates: try store.causalSequenceStates()
            ),
            .rejectedBecause(1)
        )

        let conflicting = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000725")!,
            causalSequence: 1,
            payload: .confirm(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000735")!)
        )
        XCTAssertEqual(try store.ingest(conflicting), .accepted)
        XCTAssertEqual(try store.causalSequenceStates()[1], .conflict)
        XCTAssertEqual(
            WatchCommandDependencyPolicy.decision(
                for: successor,
                sequenceStates: try store.causalSequenceStates()
            ),
            .rejectedBecause(1)
        )
    }

    func testTerminalCausalWatermarkStopsAtMissingAndPendingSequences() throws {
        let store = try makeStore()
        func command(_ sequence: Int) -> WatchMessageEnvelope {
            WatchMessageEnvelope(
                causalSequence: sequence,
                payload: .confirm(actionID: UUID())
            )
        }

        let second = command(2)
        XCTAssertEqual(try store.ingest(second), .accepted)
        try store.setState(WatchReceiptState.rejected, for: second.messageID)
        XCTAssertNil(try store.highestContiguousTerminalCausalSequence())

        let first = command(1)
        XCTAssertEqual(try store.ingest(first), .accepted)
        XCTAssertNil(try store.highestContiguousTerminalCausalSequence())
        try store.setState(WatchReceiptState.processed, for: first.messageID)
        XCTAssertEqual(try store.highestContiguousTerminalCausalSequence(), 2)

        let fourth = command(4)
        let fifth = command(5)
        XCTAssertEqual(try store.ingest(fourth), .accepted)
        XCTAssertEqual(try store.ingest(fifth), .accepted)
        try store.setState(WatchReceiptState.processed, for: fourth.messageID)
        try store.setState(WatchReceiptState.rejected, for: fifth.messageID)
        XCTAssertEqual(try store.highestContiguousTerminalCausalSequence(), 2)

        let third = command(3)
        XCTAssertEqual(try store.ingest(third), .accepted)
        XCTAssertEqual(try store.highestContiguousTerminalCausalSequence(), 2)
        try store.setState(WatchReceiptState.rejected, for: third.messageID)
        XCTAssertEqual(try store.highestContiguousTerminalCausalSequence(), 5)
    }

    func testCausalTranscriptWaitsForPredecessorAndStaysPendingUntilConsumed() throws {
        let store = try makeStore()
        let transcript = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000726")!,
            causalSequence: 2,
            dependsOn: 1,
            payload: .transcript("记录午餐")
        )
        let predecessor = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000727")!,
            causalSequence: 1,
            payload: .confirm(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000737")!)
        )

        XCTAssertEqual(try store.ingest(transcript), .accepted)
        XCTAssertEqual(try store.pendingTranscripts().map(\.messageID), [transcript.messageID])
        XCTAssertNil(try store.nextEligibleTranscript())
        XCTAssertEqual(try store.ingest(predecessor), .accepted)
        XCTAssertNil(try store.nextEligibleTranscript())
        try store.setState(WatchReceiptState.processed, for: predecessor.messageID)
        XCTAssertEqual(try store.nextEligibleTranscript()?.messageID, transcript.messageID)
        XCTAssertTrue(try store.pendingReplayEnvelopes().map(\.messageID).contains(transcript.messageID))

        try store.setState(WatchReceiptState.processed, for: transcript.messageID)
        XCTAssertTrue(try store.pendingTranscripts().isEmpty)
        XCTAssertEqual(try store.causalSequenceStates(), [1: .processed, 2: .processed])
    }

    func testLegacyPendingCommandAndTranscriptBlockNewerCommandUntilCompleted() throws {
        let store = try makeStore()
        let transcript = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000728")!,
            payload: .transcript("记录训练")
        )
        let legacyCommand = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000730")!,
            payload: .reject(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000740")!)
        )
        let newerCommand = WatchMessageEnvelope(
            messageID: UUID(uuidString: "00000000-0000-0000-0000-000000000729")!,
            causalSequence: 1,
            payload: .confirm(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000739")!)
        )
        XCTAssertEqual(try store.ingest(transcript), .accepted)
        XCTAssertEqual(try store.ingest(legacyCommand), .accepted)
        XCTAssertEqual(try store.ingest(newerCommand), .accepted)
        XCTAssertTrue(try store.hasEarlierPendingCommand(before: legacyCommand.messageID))
        XCTAssertTrue(try store.hasEarlierPendingCommand(before: newerCommand.messageID))
        XCTAssertEqual(try store.pendingTranscripts().map(\.messageID), [transcript.messageID])

        try store.setState(WatchReceiptState.processed, for: transcript.messageID)
        XCTAssertTrue(try store.hasEarlierPendingCommand(before: newerCommand.messageID))
        try store.setState(WatchReceiptState.processed, for: legacyCommand.messageID)
        XCTAssertFalse(try store.hasEarlierPendingCommand(before: newerCommand.messageID))
    }

    func testPendingCommandQueryMatchesZeroUUIDAndSkipsNilRequestIDInArrivalOrder() throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WatchMessageInboxStore(modelContainer: container)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let zeroID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let nilRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let firstEnvelope = WatchMessageEnvelope(
            messageID: firstID,
            payload: .confirm(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
        )
        let nilRequestEnvelope = WatchMessageEnvelope(
            messageID: nilRequestID,
            payload: .reject(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
        )
        let zeroEnvelope = WatchMessageEnvelope(
            messageID: zeroID,
            payload: .confirm(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!)
        )

        XCTAssertEqual(try store.ingest(firstEnvelope), .accepted)
        let context = ModelContext(container)
        context.insert(MessageRecord(
            conversationID: WatchMessageInboxStore.conversationID,
            roleRaw: "watch-envelope",
            contentData: try WatchMessageCodec.encode(nilRequestEnvelope),
            ordinal: 1,
            requestID: nil
        ))
        try context.save()
        XCTAssertEqual(try store.ingest(zeroEnvelope), .accepted)

        let pendingCommands = try store.pendingCommandEnvelopes()
        XCTAssertEqual(pendingCommands.map(\.messageID), [firstID, zeroID])
        XCTAssertEqual(
            pendingCommands.map(\.payload),
            [firstEnvelope.payload, zeroEnvelope.payload]
        )
        XCTAssertEqual(try store.recentReceivedMessageIDs(), [firstID, zeroID])
    }

    func testPendingInboxOrdersEqualOrdinalsByMessageIDAcrossReceiptPages() throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WatchMessageInboxStore(modelContainer: container)
        let firstRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let laterRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000065")!
        let firstPageMessageRowID = UUID(uuidString: "f0000000-0000-0000-0000-000000000001")!
        let secondPageMessageRowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let firstEnvelope = WatchMessageEnvelope(
            messageID: firstRequestID,
            payload: .confirm(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000071")!)
        )
        let laterEnvelope = WatchMessageEnvelope(
            messageID: laterRequestID,
            payload: .reject(actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000072")!)
        )
        let context = ModelContext(container)

        for index in 1...65 {
            let receiptID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
            context.insert(WatchMessageReceiptRecord(
                messageID: receiptID.uuidString.lowercased(),
                schemaVersion: WatchMessageEnvelope.currentSchemaVersion,
                payloadHash: "fixture-\(index)"
            ))
        }
        context.insert(MessageRecord(
            id: secondPageMessageRowID,
            conversationID: WatchMessageInboxStore.conversationID,
            roleRaw: "watch-envelope",
            contentData: try WatchMessageCodec.encode(laterEnvelope),
            ordinal: 4,
            requestID: laterRequestID
        ))
        context.insert(MessageRecord(
            id: firstPageMessageRowID,
            conversationID: WatchMessageInboxStore.conversationID,
            roleRaw: "watch-envelope",
            contentData: try WatchMessageCodec.encode(firstEnvelope),
            ordinal: 4,
            requestID: firstRequestID
        ))
        try context.save()

        let pendingCommands = try store.pendingCommandEnvelopes()

        XCTAssertEqual(pendingCommands.map(\.messageID), [laterRequestID, firstRequestID])
        XCTAssertEqual(pendingCommands.map(\.payload), [laterEnvelope.payload, firstEnvelope.payload])
    }

    func testPendingInboxPagesMoreThan64ReceiptsInArrivalOrder() throws {
        let store = try makeStore()
        var expectedTranscriptIDs: [UUID] = []
        var expectedCommandIDs: [UUID] = []

        for index in 0..<65 {
            let messageID = UUID()
            let envelope: WatchMessageEnvelope
            if index.isMultiple(of: 2) {
                envelope = WatchMessageEnvelope(
                    messageID: messageID,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(100 - index)),
                    payload: .transcript("语音记录 \(index)")
                )
                expectedTranscriptIDs.append(messageID)
            } else {
                envelope = WatchMessageEnvelope(
                    messageID: messageID,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(100 - index)),
                    payload: .confirm(actionID: UUID())
                )
                expectedCommandIDs.append(messageID)
            }
            XCTAssertEqual(try store.ingest(envelope), .accepted)
        }

        XCTAssertEqual(try store.pendingTranscripts().map(\.messageID), expectedTranscriptIDs)
        XCTAssertEqual(try store.pendingCommandEnvelopes().map(\.messageID), expectedCommandIDs)
        XCTAssertEqual(try store.receiptCount(), 65)
    }

    func testRecentInboxQueriesFilterStatesAndApplyLimitsInArrivalOrder() throws {
        let store = try makeStore()
        let messages = (0..<4).map { index in
            WatchMessageEnvelope(
                messageID: UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000007%02d", 20 + index))!,
                createdAt: Date(timeIntervalSince1970: TimeInterval(100 - index)),
                payload: .transcript("记录 \(index)")
            )
        }

        for message in messages {
            XCTAssertEqual(try store.ingest(message), .accepted)
        }
        try store.setState(WatchReceiptState.processed, for: messages[0].messageID)
        try store.setState(WatchReceiptState.rejected, for: messages[1].messageID)

        XCTAssertEqual(
            Set(try store.recentProcessedMessageIDs(limit: 2)),
            Set([messages[0].messageID, messages[1].messageID])
        )
        XCTAssertEqual(try store.recentProcessedMessageIDs(limit: 1).count, 1)
        XCTAssertEqual(
            try store.recentReceivedMessageIDs(limit: 2),
            [messages[2].messageID, messages[3].messageID]
        )
        XCTAssertEqual(
            try store.pendingTranscripts(excluding: [messages[2].messageID]).map(\.messageID),
            [messages[3].messageID]
        )
        XCTAssertTrue(try store.recentProcessedMessageIDs(limit: 0).isEmpty)
        XCTAssertTrue(try store.recentReceivedMessageIDs(limit: -1).isEmpty)
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
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return WatchMessageInboxStore(modelContainer: container)
    }
}
