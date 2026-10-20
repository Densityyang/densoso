import DensosoDomain
import Foundation

protocol ConfirmationRepository: Sendable {
    func stage(
        payload: ActionPayload,
        payloadData: Data,
        canonicalPayloadData: Data,
        idempotencyKey: String,
        clientRequestID: UUID,
        createdAt: Date,
        expiresAt: Date
    ) async throws -> PendingAction

    func activeActions(now: Date) async throws -> [PendingAction]
    func confirm(id: UUID, now: Date) async throws -> CommitReceipt
    func reject(id: UUID, now: Date) async throws
    func recoverInterruptedCommits(now: Date) async throws
}

enum ConfirmationError: Equatable, Sendable, SharedErrorDescribing {
    case notFound
    case expired
    case rejected
    case alreadyCommitting
    case payloadCorrupt
    case persistenceReadOnly(diagnosticID: String)
    case unsupportedAction
    case invariantViolation(String)
    case commitFailed(retryable: Bool)

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
        }
    }

    var isRetryable: Bool {
        switch self {
        case .alreadyCommitting, .persistenceReadOnly:
            return true
        case .commitFailed(let retryable):
            return retryable
        case .notFound, .expired, .rejected, .payloadCorrupt, .unsupportedAction, .invariantViolation:
            return false
        }
    }

    var errorDescription: String? {
        sharedErrorDescriptor.userMessage
    }
}
