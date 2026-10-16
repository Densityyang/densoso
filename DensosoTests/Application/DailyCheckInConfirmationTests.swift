import DensosoDomain
import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class DailyCheckInConfirmationTests: XCTestCase {
    func testToolCreatesOnlyPendingActionUntilUserConfirms() async throws {
        let container = try makeV5Container()
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let tool = StageDailyCheckInTool()
        let draft = try tool.draft(
            argumentsJSON: #"{"energy":"low","stress":"elevated","subjectiveSleep":"poor","note":"  昨晚醒了几次  "}"#,
            asOf: date
        )
        let repository = SwiftDataConfirmationRepository(modelContainer: container)
        let outbox = CountingHealthSyncOutbox()
        let coordinator = ConfirmationCoordinator(
            repository: repository,
            writeGate: PersistenceWriteGate(state: .writable),
            now: { date },
            healthSyncOutbox: outbox
        )
        let checkInPayload = ActionPayload.dailyCheckIn(draft)

        let pending = try await coordinator.stage(payload: checkInPayload, clientRequestID: UUID())
        XCTAssertEqual(pending.payload, checkInPayload)
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingActionRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyCheckInRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
        XCTAssertEqual(outbox.processCount, 0)

        let receipt = try await coordinator.confirm(id: pending.id)

        XCTAssertEqual(receipt.actionType, .dailyCheckIn)
        XCTAssertEqual(receipt.healthSyncState, .notApplicable)
        XCTAssertTrue(receipt.outboxIDs.isEmpty)
        XCTAssertEqual(outbox.processCount, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyCheckInRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyHealthSnapshotRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyMetrics>()), 0)
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<DailyCheckInRecord>()).first)
        XCTAssertEqual(stored.sourceActionKey, pending.idempotencyKey)
        XCTAssertEqual(stored.occurredAt, date)
        XCTAssertEqual(stored.energyRaw, "low")
        XCTAssertEqual(stored.stressRaw, "elevated")
        XCTAssertEqual(stored.subjectiveSleepRaw, "poor")
        XCTAssertEqual(stored.note, "昨晚醒了几次")
        XCTAssertEqual(stored.sourceRaw, "userReported")
        XCTAssertEqual(receipt.localRecordID, stored.id)
    }

    func testRejectingCheckInNeverPersistsTheUserReportedFact() async throws {
        let container = try makeV5Container()
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let repository = SwiftDataConfirmationRepository(modelContainer: container)
        let coordinator = ConfirmationCoordinator(
            repository: repository,
            writeGate: PersistenceWriteGate(state: .writable),
            now: { date }
        )
        let pending = try await coordinator.stage(
            payload: .dailyCheckIn(DailyCheckIn(
                occurredAt: date,
                energy: .low,
                stress: .elevated,
                subjectiveSleep: .poor
            )),
            clientRequestID: UUID()
        )

        try await coordinator.reject(id: pending.id)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyCheckInRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CommittedActionReceiptRecord>()), 0)
    }

    func testCanonicalPayloadNormalizesNoteAndRejectsOversizedNote() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = ActionPayload.dailyCheckIn(DailyCheckIn(
            occurredAt: date,
            energy: .typical,
            stress: .low,
            subjectiveSleep: .fair,
            note: "  user report  "
        ))
        let canonical = try payload.canonicalData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: canonical) as? [String: Any])
        XCTAssertEqual(object["actionType"] as? String, "dailyCheckIn")
        let canonicalPayload = try XCTUnwrap(object["payload"] as? [String: Any])
        let values = try XCTUnwrap(canonicalPayload["dailyCheckIn"] as? [String: Any])
        XCTAssertEqual(values["note"] as? String, "user report")
        XCTAssertNil(values["healthKitSamples"])

        let oversized = ActionPayload.dailyCheckIn(DailyCheckIn(
            occurredAt: date,
            energy: .typical,
            stress: .low,
            subjectiveSleep: .fair,
            note: String(repeating: "a", count: 501)
        ))
        XCTAssertThrowsError(try oversized.canonicalData()) { error in
            XCTAssertEqual(error as? CanonicalizationError, .outOfRange(field: "dailyCheckIn.note"))
        }
    }

    func testToolUsesStrictStagingSchemaAndParsesExplicitSelfReportOnly() throws {
        let tool = StageDailyCheckInTool()
        XCTAssertEqual(tool.definition.name, "stage_daily_checkin")
        XCTAssertEqual(tool.definition.effect, .stagesAction)
        guard case .object(_, let required, let additionalProperties, _) = tool.definition.parameters else {
            return XCTFail("stage_daily_checkin must use a closed object schema")
        }
        XCTAssertEqual(Set(required), Set(["energy", "stress", "subjectiveSleep"]))
        XCTAssertFalse(additionalProperties)
        XCTAssertNoThrow(try ToolSchemaValidator.validate(.object([
            "energy": .string("low"),
            "stress": .string("elevated"),
            "subjectiveSleep": .string("poor"),
        ]), against: tool.definition.parameters))

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = try tool.draft(
            argumentsJSON: #"{"energy":"low","stress":"elevated","subjectiveSleep":"poor","occurredAt":null,"note":null}"#,
            asOf: date
        )
        XCTAssertEqual(draft.occurredAt, date)
        XCTAssertEqual(draft.energy, .low)
        XCTAssertEqual(draft.stress, .elevated)
        XCTAssertEqual(draft.subjectiveSleep, .poor)
        XCTAssertNil(draft.note)
        let oversizedArguments = try JSONSerialization.data(withJSONObject: [
            "energy": "low",
            "stress": "elevated",
            "subjectiveSleep": "poor",
            "note": String(repeating: "x", count: 501),
        ])
        XCTAssertThrowsError(try tool.draft(
            argumentsJSON: String(decoding: oversizedArguments, as: UTF8.self),
            asOf: date
        ))
    }

    func testV4StoreMigratesToV5WithAnEmptyCheckInLedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso-checkin-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        try createV4Store(at: storeURL)

        let schema = Schema(versionedSchema: DensosoSchemaV5.self)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DensosoMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyCheckInRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ConversationRecord>()), 1)
    }

    private func makeV5Container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV5.self)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func createV4Store(at storeURL: URL) throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(ConversationRecord())
        try context.save()
    }
}

@MainActor
private final class CountingHealthSyncOutbox: HealthSyncOutboxProcessing {
    private(set) var processCount = 0

    func processPending() async {
        processCount += 1
    }
}
