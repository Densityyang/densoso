import DensosoDomain
import Foundation

enum ConfirmationConversationIdentity {
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

@MainActor
protocol HealthSyncOutboxProcessing: Sendable {
    func processPending() async
}

actor ConfirmationCoordinator {
    static let defaultConversationID = ConfirmationConversationIdentity.defaultID

    private let repository: any ConfirmationRepository
    private let writeGate: PersistenceWriteGate
    private let idempotencyKeyFactory: ActionIdempotencyKeyFactory
    private let now: @Sendable () -> Date
    private let timeToLive: TimeInterval
    private let healthSyncOutbox: (any HealthSyncOutboxProcessing)?

    init(
        repository: any ConfirmationRepository,
        writeGate: PersistenceWriteGate,
        idempotencyKeyFactory: ActionIdempotencyKeyFactory = .init(),
        timeToLive: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = Date.init,
        healthSyncOutbox: (any HealthSyncOutboxProcessing)? = nil
    ) {
        self.repository = repository
        self.writeGate = writeGate
        self.idempotencyKeyFactory = idempotencyKeyFactory
        self.timeToLive = timeToLive
        self.now = now
        self.healthSyncOutbox = healthSyncOutbox
    }

    func stage(
        payload: ActionPayload,
        clientRequestID: UUID,
        conversationID: UUID = ConfirmationConversationIdentity.defaultID
    ) async throws -> PendingAction {
        try requireWritable()
        let schemaVersion = ActionPayload.currentSchemaVersion
        let canonicalData = try payload.canonicalData(schemaVersion: schemaVersion)
        let canonicalPayloadHash = try payload.canonicalPayloadHash(schemaVersion: schemaVersion)
        let idempotencyKey = idempotencyKeyFactory.make(
            actionType: payload.actionType,
            canonicalPayloadData: canonicalData,
            clientRequestID: clientRequestID
        )
        let createdAt = now()
        return try await repository.stage(
            payload: payload,
            canonicalPayloadData: canonicalData,
            canonicalPayloadHash: canonicalPayloadHash,
            idempotencyKey: idempotencyKey,
            clientRequestID: clientRequestID,
            conversationID: conversationID,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(timeToLive)
        )
    }

    func activeActions(
        conversationID: UUID = ConfirmationConversationIdentity.defaultID
    ) async throws -> [PendingAction] {
        try await repository.activeActions(conversationID: conversationID, now: now())
    }

    func confirm(
        action: PendingAction,
        conversationID: UUID = ConfirmationConversationIdentity.defaultID
    ) async throws -> CommitReceipt {
        try requireWritable()
        guard let expectedPayloadHash = action.canonicalPayloadHash else {
            throw ConfirmationError.payloadHashMismatch
        }
        let displayedPayloadHash: String
        do {
            displayedPayloadHash = try action.payload.canonicalPayloadHash()
        } catch {
            throw ConfirmationError.payloadCorrupt
        }
        guard displayedPayloadHash == expectedPayloadHash else {
            throw ConfirmationError.payloadHashMismatch
        }
        let receipt = try await repository.confirm(
            id: action.id,
            conversationID: conversationID,
            expectedPayloadHash: expectedPayloadHash,
            now: now()
        )
        if receipt.actionType == .meal || receipt.actionType == .weight {
            await healthSyncOutbox?.processPending()
        }
        return receipt
    }

    func reject(
        id: UUID,
        conversationID: UUID = ConfirmationConversationIdentity.defaultID
    ) async throws {
        try requireWritable()
        try await repository.reject(id: id, conversationID: conversationID, now: now())
    }

    func recoverInterruptedCommits() async throws {
        try requireWritable()
        try await repository.recoverInterruptedCommits(now: now())
    }

    private func requireWritable() throws {
        do {
            try writeGate.requireWritable()
        } catch let error as PersistenceWriteError {
            switch error {
            case .recoveryReadOnly(let diagnosticID):
                throw ConfirmationError.persistenceReadOnly(diagnosticID: diagnosticID)
            }
        }
    }
}
