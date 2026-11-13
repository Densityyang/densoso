import DensosoDomain
import Foundation

protocol ConfirmationRepository: Sendable {
    func beginToolExecution(_ entry: ToolExecutionJournalEntry) async throws -> ToolExecutionJournalEntry
    func storePreparedToolPayload(
        invocationID: String,
        payloadData: Data,
        updatedAt: Date
    ) async throws
    func completeToolExecution(
        invocationID: String,
        resultData: Data,
        updatedAt: Date
    ) async throws
    func failToolExecution(
        invocationID: String,
        resultData: Data?,
        updatedAt: Date
    ) async throws
    func interruptToolExecution(
        invocationID: String,
        updatedAt: Date
    ) async throws
    func rejectAndUpdateLinkedToolExecution(
        pendingActionID: UUID,
        conversationID: UUID,
        failureResultData: Data,
        updatedAt: Date
    ) async throws
    func toolExecutionJournal(
        requestID: UUID,
        conversationID: UUID
    ) async throws -> [ToolExecutionJournalEntry]

    func stage(
        payload: ActionPayload,
        canonicalPayloadData: Data,
        canonicalPayloadHash: String,
        idempotencyKey: String,
        clientRequestID: UUID,
        conversationID: UUID,
        createdAt: Date,
        expiresAt: Date
    ) async throws -> PendingAction
    func stageToolAction(
        payload: ActionPayload,
        canonicalPayloadData: Data,
        canonicalPayloadHash: String,
        idempotencyKey: String,
        clientRequestID: UUID,
        conversationID: UUID,
        createdAt: Date,
        expiresAt: Date,
        invocationID: String,
        requestDeadline: Date?
    ) async throws -> PendingAction

    func activeActions(conversationID: UUID, now: Date) async throws -> [PendingAction]
    func confirm(
        id: UUID,
        conversationID: UUID,
        expectedPayloadHash: String,
        now: Date
    ) async throws -> CommitReceipt
    func reject(id: UUID, conversationID: UUID, now: Date) async throws
    func recoverInterruptedCommits(now: Date) async throws
}

extension ConfirmationRepository {
    // Lightweight repositories used by read-only/unit tests do not need a durable
    // journal. The SwiftData implementation overrides these methods.
    func beginToolExecution(_ entry: ToolExecutionJournalEntry) async throws -> ToolExecutionJournalEntry { entry }
    func storePreparedToolPayload(invocationID: String, payloadData: Data, updatedAt: Date) async throws {}
    func completeToolExecution(invocationID: String, resultData: Data, updatedAt: Date) async throws {}
    func failToolExecution(invocationID: String, resultData: Data?, updatedAt: Date) async throws {}
    func interruptToolExecution(invocationID: String, updatedAt: Date) async throws {}
    func rejectAndUpdateLinkedToolExecution(
        pendingActionID: UUID,
        conversationID: UUID,
        failureResultData: Data,
        updatedAt: Date
    ) async throws {
        try await reject(id: pendingActionID, conversationID: conversationID, now: updatedAt)
    }
    func toolExecutionJournal(requestID: UUID, conversationID: UUID) async throws -> [ToolExecutionJournalEntry] { [] }
    func stageToolAction(
        payload: ActionPayload,
        canonicalPayloadData: Data,
        canonicalPayloadHash: String,
        idempotencyKey: String,
        clientRequestID: UUID,
        conversationID: UUID,
        createdAt: Date,
        expiresAt: Date,
        invocationID: String,
        requestDeadline: Date? = nil
    ) async throws -> PendingAction {
        try await stage(
            payload: payload,
            canonicalPayloadData: canonicalPayloadData,
            canonicalPayloadHash: canonicalPayloadHash,
            idempotencyKey: idempotencyKey,
            clientRequestID: clientRequestID,
            conversationID: conversationID,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }
}

enum ConfirmationError: Equatable, Sendable, SharedErrorDescribing {
    case notFound
    case expired
    case rejected
    case alreadyCommitting
    case payloadCorrupt
    case payloadHashMismatch
    case persistenceReadOnly(diagnosticID: String)
    case unsupportedAction
    case invariantViolation(String)
    case commitFailed(retryable: Bool)
    case requestDeadlineExceeded

    var sharedErrorDescriptor: SharedErrorDescriptor {
        switch self {
        case .expired:
            SharedErrorDescriptor(
                code: .confirmationExpired,
                userMessage: "待确认操作已过期，请重新生成草稿。",
                subsystem: .confirmation,
                reason: .confirmationExpired
            )
        case .notFound:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "待确认操作不存在，请重新生成草稿。",
                subsystem: .confirmation,
                reason: .actionNotFound
            )
        case .rejected:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "该操作已拒绝，未写入健康数据。",
                subsystem: .confirmation,
                reason: .actionRejected
            )
        case .alreadyCommitting:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "该操作正在提交，请稍后查看状态。",
                subsystem: .confirmation,
                reason: .actionAlreadyCommitting
            )
        case .payloadCorrupt:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "待确认数据无法读取，请重新生成草稿。",
                subsystem: .confirmation,
                reason: .confirmationPayloadCorrupt
            )
        case .payloadHashMismatch:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "确认内容已变化，请重新检查并生成草稿。",
                subsystem: .confirmation,
                reason: .confirmationPayloadCorrupt
            )
        case .persistenceReadOnly:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "本地数据暂不可写入，请稍后重试。",
                subsystem: .confirmation,
                reason: .persistenceReadOnly
            )
        case .unsupportedAction:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "该操作类型暂不支持确认写入。",
                subsystem: .confirmation,
                reason: .unsupportedConfirmationAction
            )
        case .invariantViolation:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "该操作暂时无法完成，请重新检查后重试。",
                subsystem: .confirmation,
                reason: .confirmationInvariantViolation
            )
        case .commitFailed(let retryable):
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: retryable ? "提交失败，请稍后重试。" : "提交失败，请重新检查该操作。",
                subsystem: .confirmation,
                reason: .confirmationCommitFailed
            )
        case .requestDeadlineExceeded:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "请求处理时间已到，请重新发起。",
                subsystem: .confirmation,
                reason: .confirmationCommitFailed
            )
        }
    }

    var isRetryable: Bool {
        switch self {
        case .alreadyCommitting, .persistenceReadOnly:
            return true
        case .commitFailed(let retryable):
            return retryable
        case .notFound, .expired, .rejected, .payloadCorrupt, .payloadHashMismatch, .unsupportedAction,
             .invariantViolation, .requestDeadlineExceeded:
            return false
        }
    }

    var errorDescription: String? {
        sharedErrorDescriptor.userMessage
    }
}
