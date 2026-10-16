import DensosoDomain
import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class UserPreferenceConfirmationTests: XCTestCase {
    func testToolCreatesOnlyPendingActionUntilConfirmedPreferenceIsSaved() async throws {
        let container = try makeV5Container()
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let tool = StageUserPreferenceTool()
        let preference = try tool.draft(
            argumentsJSON: #"{"category":"food","statement":"  不吃香菜  "}"#,
            asOf: date
        )
        XCTAssertEqual(preference.statement, "不吃香菜")
        XCTAssertEqual(preference.source, .userReported)

        let repository = SwiftDataConfirmationRepository(modelContainer: container)
        let outbox = PreferenceCountingHealthSyncOutbox()
        let coordinator = ConfirmationCoordinator(
            repository: repository,
            writeGate: PersistenceWriteGate(state: .writable),
            now: { date },
            healthSyncOutbox: outbox
        )
        let pending = try await coordinator.stage(
            payload: .userPreference(preference),
            clientRequestID: UUID()
        )

        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingActionRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserPreferenceRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
        XCTAssertEqual(outbox.processCount, 0)

        let receipt = try await coordinator.confirm(id: pending.id)

        XCTAssertEqual(receipt.actionType, .userPreference)
        XCTAssertEqual(receipt.healthSyncState, .notApplicable)
        XCTAssertTrue(receipt.outboxIDs.isEmpty)
        XCTAssertEqual(receipt.localRecordID, preference.id)
        XCTAssertEqual(outbox.processCount, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserPreferenceRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyMetrics>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyHealthSnapshotRecord>()), 0)

        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<UserPreferenceRecord>()).first)
        XCTAssertEqual(stored.id, preference.id)
        XCTAssertEqual(stored.sourceActionKey, pending.idempotencyKey)
        XCTAssertEqual(stored.categoryRaw, "food")
        XCTAssertEqual(stored.statement, "不吃香菜")
        XCTAssertEqual(stored.sourceRaw, "userReported")
        XCTAssertEqual(stored.createdAt, date)
    }

    func testRejectingPreferenceNeverWritesPreferenceRecord() async throws {
        let container = try makeV5Container()
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = ConfirmationCoordinator(
            repository: SwiftDataConfirmationRepository(modelContainer: container),
            writeGate: PersistenceWriteGate(state: .writable),
            now: { date }
        )
        let pending = try await coordinator.stage(
            payload: .userPreference(UserPreference(category: .exercise, statement: "偏好户外运动", createdAt: date)),
            clientRequestID: UUID()
        )

        try await coordinator.reject(id: pending.id)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserPreferenceRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CommittedActionReceiptRecord>()), 0)
    }

    func testToolUsesClosedSchemaAndAcceptsOnlyExplicitPreferenceFields() throws {
        let tool = StageUserPreferenceTool()
        XCTAssertEqual(tool.definition.name, "stage_user_preference")
        XCTAssertEqual(tool.definition.effect, .stagesAction)
        guard case .object(let properties, let required, let additionalProperties, _) = tool.definition.parameters else {
            return XCTFail("stage_user_preference must use a closed object schema")
        }
        XCTAssertEqual(Set(properties.keys), ["category", "statement"])
        XCTAssertEqual(Set(required), ["category", "statement"])
        XCTAssertFalse(additionalProperties)
        XCTAssertNoThrow(try ToolSchemaValidator.validate(.object([
            "category": .string("communication"),
            "statement": .string("简洁直接地沟通"),
        ]), against: tool.definition.parameters))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(.object([
            "category": .string("healthKit"),
            "statement": .string("偏好"),
        ]), against: tool.definition.parameters))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(.object([
            "category": .string("food"),
            "statement": .string("偏好"),
            "source": .string("inferred"),
        ]), against: tool.definition.parameters))

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertThrowsError(try tool.draft(
            argumentsJSON: #"{"category":"food","statement":"   "}"#,
            asOf: date
        ))
        XCTAssertThrowsError(try tool.draft(
            argumentsJSON: #"{"category":"food","statement":"偏好","source":"inferred"}"#,
            asOf: date
        ))
        let oversizedData = try JSONSerialization.data(withJSONObject: [
            "category": "food",
            "statement": String(repeating: "x", count: 501),
        ])
        XCTAssertThrowsError(try tool.draft(
            argumentsJSON: String(decoding: oversizedData, as: UTF8.self),
            asOf: date
        ))
    }

    func testSystemPromptLimitsPreferencesToExplicitUserReportsAndLocalStorage() {
        let prompt = AgentSystemPrompt().text
        XCTAssertTrue(prompt.contains("用户明确表达后记录"))
        XCTAssertTrue(prompt.contains("绝不能从 HealthKit、生理数据或历史行为推断"))
        XCTAssertTrue(prompt.contains("不得自动加入云端上下文"))
    }

    func testCanonicalPayloadIgnoresGeneratedIdentityAndNormalizesStatement() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ActionPayload.userPreference(UserPreference(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            category: .food,
            statement: "  不吃香菜  ",
            createdAt: date
        ))
        let second = ActionPayload.userPreference(UserPreference(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            category: .food,
            statement: "不吃香菜",
            createdAt: date.addingTimeInterval(60)
        ))

        let canonicalData = try first.canonicalData()
        XCTAssertEqual(canonicalData, try second.canonicalData())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: canonicalData) as? [String: Any])
        XCTAssertEqual(object["actionType"] as? String, "userPreference")
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        let preference = try XCTUnwrap(payload["userPreference"] as? [String: Any])
        XCTAssertEqual(preference["category"] as? String, "food")
        XCTAssertEqual(preference["statement"] as? String, "不吃香菜")
        XCTAssertEqual(preference["source"] as? String, "userReported")
        XCTAssertNil(preference["healthKitSamples"])

        XCTAssertThrowsError(try ActionPayload.userPreference(UserPreference(
            category: .food,
            statement: String(repeating: "x", count: 501)
        )).canonicalData())
    }

    func testV4StoreMigratesToV5WithAnEmptyPreferenceLedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso-preference-migration-\(UUID().uuidString)", isDirectory: true)
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

        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<UserPreferenceRecord>()), 0)
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
private final class PreferenceCountingHealthSyncOutbox: HealthSyncOutboxProcessing {
    private(set) var processCount = 0

    func processPending() async {
        processCount += 1
    }
}
