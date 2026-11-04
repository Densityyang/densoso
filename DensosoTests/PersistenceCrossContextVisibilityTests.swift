import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class PersistenceCrossContextVisibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMainContextWriteIsVisibleToModelActorRead() async throws {
        let container = try makeContainer()
        let repository = SwiftDataConfirmationRepository(modelContainer: container)
        let action = try await stagePreference(using: repository)
        let mainContext = ModelContext(container)
        let actionID = action.id
        let record = try XCTUnwrap(mainContext.fetch(
            FetchDescriptor<PendingActionRecord>(predicate: #Predicate { $0.id == actionID })
        ).first)
        record.stateRaw = PendingActionState.rejected.rawValue
        try mainContext.save()

        let actorRead = try await repository.activeActions(conversationID: action.conversationID, now: now)

        XCTAssertFalse(actorRead.contains { $0.id == action.id })
        let persistedContext = ModelContext(container)
        let persistedRecord = try XCTUnwrap(persistedContext.fetch(
            FetchDescriptor<PendingActionRecord>(predicate: #Predicate { $0.id == actionID })
        ).first)
        XCTAssertEqual(persistedRecord.stateRaw, PendingActionState.rejected.rawValue)
    }

    func testModelActorWriteIsVisibleToAnotherModelActorAndMainContext() async throws {
        let container = try makeContainer()
        let firstRepository = SwiftDataConfirmationRepository(modelContainer: container)
        let secondRepository = SwiftDataConfirmationRepository(modelContainer: container)
        let action = try await stagePreference(using: firstRepository)

        let actorRead = try await secondRepository.activeActions(
            conversationID: action.conversationID,
            now: now
        )
        let mainContext = ModelContext(container)
        let actionID = action.id
        let persisted = try XCTUnwrap(mainContext.fetch(
            FetchDescriptor<PendingActionRecord>(predicate: #Predicate { $0.id == actionID })
        ).first)

        XCTAssertTrue(actorRead.contains { $0.id == action.id })
        XCTAssertEqual(persisted.stateRaw, PendingActionState.pending.rawValue)
    }

    func testLongLivedContextObservesModelActorStateUpdate() async throws {
        let container = try makeContainer()
        let repository = SwiftDataConfirmationRepository(modelContainer: container)
        let coordinator = ConfirmationCoordinator(
            repository: repository,
            writeGate: PersistenceWriteGate(state: .writable),
            now: { now }
        )
        let action = try await stagePreference(using: repository)
        let longLivedContext = ModelContext(container)
        let actionID = action.id
        let heldRecord = try XCTUnwrap(longLivedContext.fetch(
            FetchDescriptor<PendingActionRecord>(predicate: #Predicate { $0.id == actionID })
        ).first)

        try await coordinator.reject(id: action.id, conversationID: action.conversationID)
        let refreshedRecord = try XCTUnwrap(longLivedContext.fetch(
            FetchDescriptor<PendingActionRecord>(predicate: #Predicate { $0.id == actionID })
        ).first)

        XCTAssertEqual(heldRecord.stateRaw, PendingActionState.rejected.rawValue)
        XCTAssertEqual(refreshedRecord.stateRaw, PendingActionState.rejected.rawValue)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PendingActionRecord>()), 1)
    }

    private func stagePreference(using repository: SwiftDataConfirmationRepository) async throws -> PendingAction {
        let coordinator = ConfirmationCoordinator(
            repository: repository,
            writeGate: PersistenceWriteGate(state: .writable),
            now: { now }
        )
        return try await coordinator.stage(
            payload: .userPreference(UserPreference(
                category: .exercise,
                statement: "prefers outdoor walks",
                createdAt: now
            )),
            clientRequestID: UUID()
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
