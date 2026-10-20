import Foundation
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

    func testCausalSequenceSurvivesAcknowledgementAndOutboxRestore() throws {
        var outbox = WatchMessageOutbox()
        let first = try outbox.enqueueCausalCommand(.confirm(actionID: UUID()))
        outbox.acknowledge(.init(messageID: first.messageID, state: .accepted))
        XCTAssertEqual(outbox.pending.map(\.messageID), [first.messageID])
        XCTAssertEqual(outbox.latestPendingCausalSequence, 1)

        let priorSequence = outbox.latestPendingCausalSequence
        let second = try outbox.enqueueCausalCommand(.reject(actionID: UUID()), dependsOn: priorSequence)
        XCTAssertEqual(second.causalSequence, 2)
        XCTAssertEqual(second.dependsOn, 1)
        outbox.acknowledge(.init(messageID: first.messageID, state: .processed))
        outbox.acknowledge(.init(messageID: second.messageID, state: .rejected))
        XCTAssertNil(outbox.latestPendingCausalSequence)

        let restored = try JSONDecoder().decode(WatchMessageOutbox.self, from: JSONEncoder().encode(outbox))
        XCTAssertEqual(restored.latestCausalSequence, 2)
        var resumedOutbox = restored
        let resumedSequence = resumedOutbox.latestPendingCausalSequence
        let third = try resumedOutbox.enqueueCausalCommand(.transcript("继续记录"), dependsOn: resumedSequence)
        XCTAssertEqual(third.causalSequence, 3)
        XCTAssertNil(third.dependsOn)
    }

    func testCausalDependencyPolicyWaitsAndFailsOnRejectedOrConflictingPredecessors() {
        let successor = WatchMessageEnvelope(
            causalSequence: 2,
            dependsOn: 1,
            payload: .transcript("继续记录")
        )

        XCTAssertEqual(WatchCommandDependencyPolicy.decision(for: successor, sequenceStates: [:]), .waitingFor(1))
        XCTAssertEqual(
            WatchCommandDependencyPolicy.decision(for: successor, sequenceStates: [1: .pending]),
            .waitingFor(1)
        )
        XCTAssertEqual(
            WatchCommandDependencyPolicy.decision(for: successor, sequenceStates: [1: .processed]),
            .ready
        )
        XCTAssertEqual(
            WatchCommandDependencyPolicy.decision(for: successor, sequenceStates: [1: .rejected]),
            .rejectedBecause(1)
        )
        XCTAssertEqual(
            WatchCommandDependencyPolicy.decision(for: successor, sequenceStates: [1: .conflict]),
            .rejectedBecause(1)
        )
    }

    func testTerminalSequenceWatermarkAcknowledgesOnlyCoveredCausalEntries() {
        let legacy = WatchMessageEnvelope(payload: .transcript("旧版记录"))
        let first = WatchMessageEnvelope(causalSequence: 1, payload: .confirm(actionID: UUID()))
        let second = WatchMessageEnvelope(causalSequence: 2, dependsOn: 1, payload: .reject(actionID: UUID()))
        let third = WatchMessageEnvelope(causalSequence: 3, dependsOn: 2, payload: .transcript("后续记录"))
        var outbox = WatchMessageOutbox(pending: [legacy, first, second, third])

        XCTAssertEqual(
            Set(outbox.acknowledge(throughCausalSequence: 2)),
            Set([first.messageID, second.messageID])
        )
        XCTAssertEqual(Set(outbox.pending.map(\.messageID)), Set([legacy.messageID, third.messageID]))

        outbox.acknowledge(messageIDs: [legacy.messageID])
        XCTAssertEqual(outbox.pending.map(\.messageID), [third.messageID])
    }

    func testTodaySnapshotRoundTripsTomorrowGuidanceAndDecodesLegacyPayload() throws {
        let guidance = NextDayGuidance(
            expectedState: .caution,
            confidence: .medium,
            reasons: [EvidenceReference(key: "recovery", source: "healthState")],
            recommendedAction: .reduceIntensity,
            conditionalNote: "如果今晚恢复情况没有改善，建议把明天训练调整为轻量。"
        )
        let watchGuidance = WatchTomorrowGuidanceSummary(
            expectedState: guidance.expectedState,
            confidence: guidance.confidence,
            recommendedAction: guidance.recommendedAction,
            conditionalNote: guidance.conditionalNote
        )
        let recoverySummary = WatchRecoverySummary(
            status: .attention,
            confidence: .medium,
            recommendedAction: .reduceIntensity
        )
        let legacyDomain = HealthDomainResult(
            domain: .nutrition,
            status: .learning,
            currentValue: 1840,
            baseline: HealthBaseline(
                readiness: .learning,
                validDays: 2,
                median: 1720,
                p10: 1400,
                p90: 2050,
                mad: 120
            ),
            evidenceKeys: ["nutrition.energyIntakeKcal"]
        )
        let domain = WatchHealthDomainStatus(domain: .nutrition, status: .learning)
        let snapshot = WatchTodaySnapshot(
            summary: "今天的本地摘要",
            domains: [domain],
            pendingActions: [],
            workoutPlans: [],
            acknowledgedMessageIDs: [],
            terminalCausalSequenceWatermark: 12,
            tomorrowGuidance: watchGuidance,
            recoverySummary: recoverySummary
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedDomains = try XCTUnwrap(encodedObject["domains"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(encodedDomains.first).keys), ["domain", "status"])
        XCTAssertFalse(encodedObject.keys.contains("energyIntakeKcal"))
        XCTAssertFalse(encodedObject.keys.contains("totalExpenditureKcal"))
        XCTAssertFalse(encodedObject.keys.contains("deficitKcal"))
        let roundTripped = try JSONDecoder().decode(WatchTodaySnapshot.self, from: encoded)
        XCTAssertEqual(roundTripped.tomorrowGuidance, watchGuidance)
        XCTAssertEqual(roundTripped.recoverySummary, recoverySummary)
        XCTAssertEqual(roundTripped.terminalCausalSequenceWatermark, 12)
        XCTAssertEqual(roundTripped.domains, [domain])

        var legacyPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyPayload["energyIntakeKcal"] = 1_800
        legacyPayload["totalExpenditureKcal"] = 2_100
        legacyPayload["deficitKcal"] = -300
        legacyPayload.removeValue(forKey: "terminalCausalSequenceWatermark")
        legacyPayload["tomorrowGuidance"] = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(guidance)) as? [String: Any]
        )
        legacyPayload.removeValue(forKey: "recoverySummary")
        legacyPayload["domains"] = [try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyDomain)) as? [String: Any]
        )]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyPayload)
        let decodedLegacyPayload = try JSONDecoder().decode(WatchTodaySnapshot.self, from: legacyData)
        XCTAssertEqual(decodedLegacyPayload.tomorrowGuidance?.reasons, [])
        XCTAssertNil(decodedLegacyPayload.recoverySummary)
        XCTAssertNil(decodedLegacyPayload.terminalCausalSequenceWatermark)
        XCTAssertEqual(decodedLegacyPayload.domains, [domain])
        let reencodedLegacyPayload = try JSONEncoder().encode(decodedLegacyPayload)
        let reencodedLegacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reencodedLegacyPayload) as? [String: Any]
        )
        XCTAssertFalse(reencodedLegacyObject.keys.contains("energyIntakeKcal"))
        XCTAssertFalse(reencodedLegacyObject.keys.contains("totalExpenditureKcal"))
        XCTAssertFalse(reencodedLegacyObject.keys.contains("deficitKcal"))
        let reencodedGuidance = try XCTUnwrap(reencodedLegacyObject["tomorrowGuidance"] as? [String: Any])
        XCTAssertEqual((reencodedGuidance["reasons"] as? [Any])?.count, 0)

        let legacyConstruction = WatchTodaySnapshot(
            summary: "旧版摘要",
            domains: [domain],
            pendingActions: [],
            acknowledgedMessageIDs: []
        )
        XCTAssertNil(legacyConstruction.tomorrowGuidance)
        XCTAssertNil(legacyConstruction.recoverySummary)
    }

    func testTodaySnapshotExpiresAtInjectedCalendarLocalMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let generatedAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 10,
            day: 19,
            hour: 23,
            minute: 55
        )))
        let beforeMidnight = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 10,
            day: 19,
            hour: 23,
            minute: 59
        )))
        let afterMidnight = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 10,
            day: 20,
            hour: 0,
            minute: 1
        )))
        let expiredAction = WatchPendingActionSummary(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!,
            title: "Expired",
            summary: "Expired action",
            expiresAt: beforeMidnight
        )
        let activeAction = WatchPendingActionSummary(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
            title: "Active",
            summary: "Still valid after midnight",
            expiresAt: afterMidnight.addingTimeInterval(3_600)
        )
        let snapshot = WatchTodaySnapshot(
            generatedAt: generatedAt,
            summary: "local summary",
            domains: [],
            pendingActions: [expiredAction, activeAction],
            acknowledgedMessageIDs: []
        )

        XCTAssertTrue(snapshot.isCurrentLocalDay(asOf: beforeMidnight, calendar: calendar))
        XCTAssertFalse(snapshot.isCurrentLocalDay(asOf: afterMidnight, calendar: calendar))
        XCTAssertEqual(snapshot.activePendingActions(asOf: afterMidnight), [activeAction])
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

    func testSnapshotRequestPolicyCoalescesOnlyUntilAcknowledged() throws {
        var outbox = WatchMessageOutbox()
        let firstRequest = WatchMessageEnvelope(payload: .requestTodaySnapshot)
        let secondRequest = WatchMessageEnvelope(payload: .requestTodaySnapshot)
        let transcript = WatchMessageEnvelope(payload: .transcript("今天跑步"))
        let confirmation = WatchMessageEnvelope(payload: .confirm(actionID: UUID()))
        let rejection = WatchMessageEnvelope(payload: .reject(actionID: UUID()))

        XCTAssertTrue(WatchSnapshotRequestCoalescingPolicy.shouldEnqueue(pendingMessages: outbox.pending))
        XCTAssertTrue(try outbox.enqueue(firstRequest))
        XCTAssertFalse(WatchSnapshotRequestCoalescingPolicy.shouldEnqueue(pendingMessages: outbox.pending))
        XCTAssertTrue(try outbox.enqueue(transcript))
        XCTAssertTrue(try outbox.enqueue(confirmation))
        XCTAssertTrue(try outbox.enqueue(rejection))

        if WatchSnapshotRequestCoalescingPolicy.shouldEnqueue(pendingMessages: outbox.pending) {
            try outbox.enqueue(secondRequest)
        }
        XCTAssertEqual(outbox.pending.count, 4)
        XCTAssertFalse(WatchSnapshotRequestCoalescingPolicy.shouldEnqueue(pendingMessages: outbox.pending))

        outbox.acknowledge(.init(messageID: firstRequest.messageID, state: .processed))
        XCTAssertTrue(WatchSnapshotRequestCoalescingPolicy.shouldEnqueue(pendingMessages: outbox.pending))
        if WatchSnapshotRequestCoalescingPolicy.shouldEnqueue(pendingMessages: outbox.pending) {
            try outbox.enqueue(secondRequest)
        }

        let pendingIDs = Set(outbox.pending.map(\.messageID))
        XCTAssertEqual(outbox.pending.count, 4)
        XCTAssertTrue(pendingIDs.contains(transcript.messageID))
        XCTAssertTrue(pendingIDs.contains(confirmation.messageID))
        XCTAssertTrue(pendingIDs.contains(rejection.messageID))
        XCTAssertTrue(pendingIDs.contains(secondRequest.messageID))
    }
}
