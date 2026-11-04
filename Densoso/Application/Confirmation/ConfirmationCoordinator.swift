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
        conversationID: UUID = ConfirmationConversationIdentity.defaultID,
        invocationID: String? = nil,
        requestDeadline: Date? = nil
    ) async throws -> PendingAction {
        try requireActiveRequest(deadline: requestDeadline)
        try requireWritable()
        let schemaVersion = ActionPayload.currentSchemaVersion
        let canonicalData = try payload.canonicalData(schemaVersion: schemaVersion)
        let canonicalPayloadHash = try payload.canonicalPayloadHash(schemaVersion: schemaVersion)
        let idempotencyKey = idempotencyKeyFactory.make(
            actionType: payload.actionType,
            canonicalPayloadData: canonicalData,
            clientRequestID: clientRequestID,
            invocationID: invocationID
        )
        let createdAt = now()
        if let invocationID {
            try requireActiveRequest(deadline: requestDeadline)
            let preparedPayloadData = try ToolExecutionPayloadCodec.encode(payload)
            try await repository.storePreparedToolPayload(
                invocationID: invocationID,
                payloadData: preparedPayloadData,
                updatedAt: createdAt
            )
        }
        try requireActiveRequest(deadline: requestDeadline)
        if let invocationID {
            return try await repository.stageToolAction(
                payload: payload,
                canonicalPayloadData: canonicalData,
                canonicalPayloadHash: canonicalPayloadHash,
                idempotencyKey: idempotencyKey,
                clientRequestID: clientRequestID,
                conversationID: conversationID,
                createdAt: createdAt,
                expiresAt: createdAt.addingTimeInterval(timeToLive),
                invocationID: invocationID,
                requestDeadline: requestDeadline
            )
        }
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

    func beginToolExecution(_ entry: ToolExecutionJournalEntry) async throws -> ToolExecutionJournalEntry {
        try await repository.beginToolExecution(entry)
    }

    func completeToolExecution(invocationID: String, resultData: Data) async throws {
        try await repository.completeToolExecution(
            invocationID: invocationID,
            resultData: resultData,
            updatedAt: now()
        )
    }

    func failToolExecution(invocationID: String, resultData: Data?) async {
        try? await repository.failToolExecution(
            invocationID: invocationID,
            resultData: resultData,
            updatedAt: now()
        )
    }

    func failToolExecutions(pendingActionID: UUID, resultData: Data) async {
        try? await repository.failToolExecutions(
            pendingActionID: pendingActionID,
            resultData: resultData,
            updatedAt: now()
        )
    }

    func toolExecutionJournal(
        requestID: UUID,
        conversationID: UUID = ConfirmationConversationIdentity.defaultID
    ) async throws -> [ToolExecutionJournalEntry] {
        try await repository.toolExecutionJournal(requestID: requestID, conversationID: conversationID)
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
        let receipt: CommitReceipt
        do {
            receipt = try await repository.confirm(
                id: action.id,
                conversationID: conversationID,
                expectedPayloadHash: expectedPayloadHash,
                now: now()
            )
        } catch let commitError {
            // The business transaction may have rolled back to its durable
            // "committing" marker, or it may have committed before a later
            // failure was reported. Reconcile from the receipt and source rows
            // now so a retry in this process does not depend on app relaunch.
            do { try await repository.recoverInterruptedCommits(now: now()) }
            catch { /* Preserve the original error; the durable marker remains retryable. */ }
            throw commitError
        }
        return receipt
    }

    /// Runs independently after the local business transaction and receipt commit.
    func processHealthSyncOutbox() async {
        await healthSyncOutbox?.processPending()
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

    private func requireActiveRequest(deadline: Date?) throws {
        try Task.checkCancellation()
        if let deadline, now() >= deadline {
            throw ConfirmationError.requestDeadlineExceeded
        }
    }
}
