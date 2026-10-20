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

    func testTodaySnapshotRoundTripsTomorrowGuidanceAndDecodesLegacyPayload() throws {
        let guidance = NextDayGuidance(
            expectedState: .caution,
            confidence: .medium,
            reasons: [EvidenceReference(key: "recovery", source: "healthState")],
            recommendedAction: .reduceIntensity,
            conditionalNote: "如果今晚恢复情况没有改善，建议把明天训练调整为轻量。"
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
            energyIntakeKcal: 1_800,
            totalExpenditureKcal: 2_100,
            deficitKcal: -300,
            domains: [domain],
            pendingActions: [],
            workoutPlans: [],
            acknowledgedMessageIDs: [],
            tomorrowGuidance: guidance,
            recoverySummary: recoverySummary
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedDomains = try XCTUnwrap(encodedObject["domains"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(encodedDomains.first).keys), ["domain", "status"])
        let roundTripped = try JSONDecoder().decode(WatchTodaySnapshot.self, from: encoded)
        XCTAssertEqual(roundTripped.tomorrowGuidance, guidance)
        XCTAssertEqual(roundTripped.recoverySummary, recoverySummary)
        XCTAssertEqual(roundTripped.domains, [domain])

        var legacyPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyPayload.removeValue(forKey: "tomorrowGuidance")
        legacyPayload.removeValue(forKey: "recoverySummary")
        legacyPayload["domains"] = [try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyDomain)) as? [String: Any]
        )]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyPayload)
        let decodedLegacyPayload = try JSONDecoder().decode(WatchTodaySnapshot.self, from: legacyData)
        XCTAssertNil(decodedLegacyPayload.tomorrowGuidance)
        XCTAssertNil(decodedLegacyPayload.recoverySummary)
        XCTAssertEqual(decodedLegacyPayload.domains, [domain])

        let legacyConstruction = WatchTodaySnapshot(
            summary: "旧版摘要",
            energyIntakeKcal: nil,
            totalExpenditureKcal: nil,
            deficitKcal: nil,
            domains: [domain],
            pendingActions: [],
            acknowledgedMessageIDs: []
        )
        XCTAssertNil(legacyConstruction.tomorrowGuidance)
        XCTAssertNil(legacyConstruction.recoverySummary)
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
