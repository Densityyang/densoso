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

enum ConfirmationError: LocalizedError, Equatable, Sendable {
    case notFound
    case expired
    case rejected
    case alreadyCommitting
    case payloadCorrupt
    case persistenceReadOnly(diagnosticID: String)
    case unsupportedAction
    case invariantViolation(String)
    case commitFailed(retryable: Bool)

    var errorDescription: String? {
        switch self {
        case .notFound: "待确认操作不存在"
        case .expired: "待确认操作已过期，请重新生成草稿"
        case .rejected: "该操作已拒绝，未写入健康数据"
        case .alreadyCommitting: "该操作正在提交"
        case .payloadCorrupt: "待确认数据无法解析"
        case .persistenceReadOnly(let diagnosticID):
            "本地数据处于只读恢复模式（\(diagnosticID)）"
        case .unsupportedAction: "该操作类型尚未开放确认写入"
        case .invariantViolation(let detail): "确认事务不变量异常：\(detail)"
        case .commitFailed(let retryable): retryable ? "提交失败，可重试" : "提交失败，需要诊断"
        }
    }
}
