import DensosoDomain
import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class GetUserPreferencesToolTests: XCTestCase {
    func testToolUsesStrictEmptyReadOnlySchemaAndExplicitRequestPolicy() throws {
        let definition = GetUserPreferencesTool().definition
        XCTAssertEqual(definition.name, "get_user_preferences")
        XCTAssertEqual(definition.effect, .readOnly)
        XCTAssertTrue(definition.description.contains("用户明确询问已记录"))
        guard case .object(let properties, let required, let additionalProperties, _) = definition.parameters else {
            return XCTFail("get_user_preferences must use a closed object schema")
        }
        XCTAssertTrue(properties.isEmpty)
        XCTAssertTrue(required.isEmpty)
        XCTAssertFalse(additionalProperties)
        XCTAssertNoThrow(try ToolSchemaValidator.validate(.object([:]), against: definition.parameters))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            .object(["limit": .integer(2)]),
            against: definition.parameters
        ))

        let prompt = AgentSystemPrompt().text
        XCTAssertTrue(prompt.contains("只有用户明确询问已记录的个人偏好时，才调用 get_user_preferences"))
        XCTAssertTrue(prompt.contains("普通回答中不要主动读取或附加这些偏好"))
    }

    func testRepositoryReturnsOnlyConfirmedUserReportedCategoriesWithoutWritesOrIDs() async throws {
        let container = try makeV5Container()
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let identifiers = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000081")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000082")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000083")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000084")!,
        ]
        context.insert(UserPreferenceRecord(
            id: identifiers[0],
            sourceActionKey: "private-food-action-key",
            categoryRaw: UserPreferenceCategory.food.rawValue,
            statement: "不吃香菜",
            createdAt: date
        ))
        context.insert(UserPreferenceRecord(
            id: identifiers[1],
            sourceActionKey: "private-exercise-action-key",
            categoryRaw: UserPreferenceCategory.exercise.rawValue,
            statement: "偏好户外步行",
            createdAt: date.addingTimeInterval(20)
        ))
        context.insert(UserPreferenceRecord(
            id: identifiers[2],
            sourceActionKey: "private-communication-action-key",
            categoryRaw: UserPreferenceCategory.communication.rawValue,
            statement: "回答简洁一些",
            createdAt: date.addingTimeInterval(10)
        ))
        context.insert(UserPreferenceRecord(
            id: identifiers[3],
            sourceActionKey: "inferred-source-action-key",
            categoryRaw: UserPreferenceCategory.food.rawValue,
            statement: "inferred-private-marker",
            sourceRaw: "inferred",
            createdAt: date.addingTimeInterval(30)
        ))
        context.insert(UserPreferenceRecord(
            sourceActionKey: "unknown-category-action-key",
            categoryRaw: "healthKit",
            statement: "unknown-category-private-marker",
            createdAt: date.addingTimeInterval(40)
        ))
        let pending = ActionPayload.userPreference(UserPreference(
            category: .food,
            statement: "unconfirmed-private-marker",
            createdAt: date
        ))
        let payloadEncoder = JSONEncoder()
        payloadEncoder.dateEncodingStrategy = .millisecondsSince1970
        context.insert(PendingActionRecord(
            idempotencyKey: "unconfirmed-private-action-key",
            actionTypeRaw: ActionType.userPreference.rawValue,
            canonicalPayloadData: try pending.canonicalData(),
            payloadData: try payloadEncoder.encode(pending),
            clientRequestID: UUID(),
            createdAt: date,
            expiresAt: date.addingTimeInterval(3_600)
        ))
        try context.save()
        let beforePreferenceCount = try context.fetchCount(FetchDescriptor<UserPreferenceRecord>())
        let beforePendingCount = try context.fetchCount(FetchDescriptor<PendingActionRecord>())
        let beforeOutboxCount = try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>())

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let preferences = try await repository.userPreferences(limit: 3)
        XCTAssertEqual(preferences.map(\.category), [.exercise, .communication, .food])
        XCTAssertEqual(preferences.map(\.statement), ["偏好户外步行", "回答简洁一些", "不吃香菜"])

        let response = try GetUserPreferencesTool().response(preferences: preferences, limit: 2)
        let object = try jsonObject(response)
        XCTAssertEqual(object["status"] as? String, "available")
        XCTAssertEqual(object["returnedCount"] as? Int, 2)
        XCTAssertEqual(object["hasMore"] as? Bool, true)
        let results = try XCTUnwrap(object["preferences"] as? [[String: Any]])
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(Set(first.keys), ["category", "statement"])
        XCTAssertEqual(first["category"] as? String, "exercise")
        XCTAssertFalse(response.contains("private-food-action-key"))
        XCTAssertFalse(response.contains("private-exercise-action-key"))
        XCTAssertFalse(response.contains("inferred-private-marker"))
        XCTAssertFalse(response.contains("unknown-category-private-marker"))
        XCTAssertFalse(response.contains("unconfirmed-private-marker"))
        for id in identifiers {
            XCTAssertFalse(response.contains(id.uuidString))
            XCTAssertFalse(response.contains(id.uuidString.lowercased()))
        }
        XCTAssertFalse(response.contains("sourceActionKey"))
        XCTAssertFalse(response.contains("createdAt"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserPreferenceRecord>()), beforePreferenceCount)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingActionRecord>()), beforePendingCount)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), beforeOutboxCount)
    }

    func testRepositoryPagesInvalidRowsAndPreservesIDOrderAcrossTimestampCutoff() async throws {
        let container = try makeV5Container()
        let context = ModelContext(container)
        let cutoffDate = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<(SwiftDataAgentRepository.userPreferenceFetchBatchSize - 1) {
            context.insert(UserPreferenceRecord(
                sourceActionKey: String(format: "invalid-%04d", index),
                categoryRaw: "unknown-category",
                statement: "skip this row",
                createdAt: cutoffDate.addingTimeInterval(Double(64 - index))
            ))
        }
        context.insert(UserPreferenceRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            sourceActionKey: "tie-a",
            categoryRaw: UserPreferenceCategory.food.rawValue,
            statement: "later ID at cutoff",
            createdAt: cutoffDate
        ))
        context.insert(UserPreferenceRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            sourceActionKey: "tie-m",
            categoryRaw: UserPreferenceCategory.food.rawValue,
            statement: "middle ID at cutoff",
            createdAt: cutoffDate
        ))
        context.insert(UserPreferenceRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            sourceActionKey: "tie-z",
            categoryRaw: UserPreferenceCategory.food.rawValue,
            statement: "lowest ID wins cutoff",
            createdAt: cutoffDate
        ))
        try context.save()

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let preferences = try await repository.userPreferences(limit: 1)

        XCTAssertEqual(preferences.map(\.statement), ["lowest ID wins cutoff"])
    }

    func testOutputSizeLimitRemovesItemsAndReportsHasMore() throws {
        let preferences = (0..<AgentUserPreferencesLimits.maximumPreferenceCount).map { _ in
            AgentUserPreference(category: .communication, statement: String(repeating: "\n", count: 500))
        }
        let response = try GetUserPreferencesTool().response(
            preferences: preferences,
            limit: AgentUserPreferencesLimits.maximumPreferenceCount
        )
        let object = try jsonObject(response)

        XCTAssertLessThanOrEqual(response.count, AgentUserPreferencesLimits.maximumOutputCharacters)
        XCTAssertLessThan(try XCTUnwrap(object["returnedCount"] as? Int), preferences.count)
        XCTAssertEqual(object["hasMore"] as? Bool, true)
    }

    func testEmptyPreferencesReturnNoPreferencesWithoutGuessing() throws {
        let response = try GetUserPreferencesTool().response(preferences: [])
        let object = try jsonObject(response)

        XCTAssertEqual(object["status"] as? String, "noPreferences")
        XCTAssertEqual(object["returnedCount"] as? Int, 0)
        XCTAssertEqual(object["hasMore"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(object["preferences"] as? [[String: Any]]).count, 0)
    }

    private func makeV5Container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV5.self)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func jsonObject(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
}
