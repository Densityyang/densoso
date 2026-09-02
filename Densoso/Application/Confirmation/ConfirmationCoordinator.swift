import DensosoDomain
import Foundation

actor ConfirmationCoordinator {
    private let repository: any ConfirmationRepository
    private let writeGate: PersistenceWriteGate
    private let idempotencyKeyFactory: ActionIdempotencyKeyFactory
    private let now: @Sendable () -> Date
    private let timeToLive: TimeInterval

    init(
        repository: any ConfirmationRepository,
        writeGate: PersistenceWriteGate,
        idempotencyKeyFactory: ActionIdempotencyKeyFactory = .init(),
        timeToLive: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repository = repository
        self.writeGate = writeGate
        self.idempotencyKeyFactory = idempotencyKeyFactory
        self.timeToLive = timeToLive
        self.now = now
    }

    func stage(payload: ActionPayload, clientRequestID: UUID) async throws -> PendingAction {
        try requireWritable()
        let canonicalData = try payload.canonicalData()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadData = try encoder.encode(payload)
        let idempotencyKey = idempotencyKeyFactory.make(
            actionType: payload.actionType,
            canonicalPayloadData: canonicalData,
            clientRequestID: clientRequestID
        )
        let createdAt = now()
        return try await repository.stage(
            payload: payload,
            payloadData: payloadData,
            canonicalPayloadData: canonicalData,
            idempotencyKey: idempotencyKey,
            clientRequestID: clientRequestID,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(timeToLive)
        )
    }

    func activeActions() async throws -> [PendingAction] {
        try await repository.activeActions(now: now())
    }

    func confirm(id: UUID) async throws -> CommitReceipt {
        try requireWritable()
        return try await repository.confirm(id: id, now: now())
    }

    func reject(id: UUID) async throws {
        try requireWritable()
        try await repository.reject(id: id, now: now())
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
