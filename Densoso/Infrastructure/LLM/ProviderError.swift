import Foundation
import DensosoDomain

enum ProviderError: Equatable, Sendable, SharedErrorDescribing {
    case configurationMissing(provider: ProviderID)
    case consentRequired(provider: ProviderID, dataClass: ProviderDataClass)
    case unauthorized(status: Int)
    case quotaExhausted(status: Int)
    case rateLimited(retryAfterSeconds: Double?)
    case requestRejected(status: Int)
    case requestTooLarge(limitBytes: Int)
    case server(status: Int)
    case network(code: Int?)
    case timeout
    case malformedResponse
    case schemaViolation(path: String)
    case contentRejected
    case unsupportedCapability(ProviderCapability)
    case cancelled
    case budgetExceeded
    case budgetUnavailable

    var sharedErrorDescriptor: SharedErrorDescriptor {
        switch self {
        case .configurationMissing:
            SharedErrorDescriptor(
                code: .providerUnavailable,
                userMessage: "AI 服务尚未配置，请在设置中检查。",
                subsystem: .provider,
                reason: .configurationMissing
            )
        case .consentRequired:
            SharedErrorDescriptor(
                code: .providerUnavailable,
                userMessage: "需要先同意本次云端数据上传。",
                subsystem: .provider,
                reason: .consentRequired
            )
        case .unauthorized(let status):
            SharedErrorDescriptor(
                code: .providerUnauthorized,
                userMessage: "暂时无法连接 AI 服务。",
                subsystem: .provider,
                reason: .unauthorized,
                numericCode: status
            )
        case .quotaExhausted(let status):
            SharedErrorDescriptor(
                code: .providerRateLimited,
                userMessage: "AI 服务当前繁忙，请稍后重试。",
                subsystem: .provider,
                reason: .quotaExhausted,
                numericCode: status
            )
        case .rateLimited:
            SharedErrorDescriptor(
                code: .providerRateLimited,
                userMessage: "AI 服务当前繁忙，请稍后重试。",
                subsystem: .provider,
                reason: .rateLimited
            )
        case .requestRejected(let status):
            SharedErrorDescriptor(
                code: .providerUnavailable,
                userMessage: "本次请求暂时无法处理，请修改后重试。",
                subsystem: .provider,
                reason: .requestRejected,
                numericCode: status
            )
        case .requestTooLarge:
            SharedErrorDescriptor(
                code: .providerUnavailable,
                userMessage: "会话内容过长，请清空部分对话后重试。",
                subsystem: .provider,
                reason: .requestTooLarge
            )
        case .server(let status):
            SharedErrorDescriptor(
                code: .providerUnavailable,
                userMessage: "AI 服务暂时不可用，请稍后重试。",
                subsystem: .provider,
                reason: .serverFailure,
                numericCode: status
            )
        case .network(let code):
            SharedErrorDescriptor(
                code: .networkUnavailable,
                userMessage: "网络连接失败，请稍后重试。",
                subsystem: .provider,
                reason: .networkFailure,
                numericCode: code
            )
        case .timeout:
            SharedErrorDescriptor(
                code: .networkUnavailable,
                userMessage: "网络连接超时，请稍后重试。",
                subsystem: .provider,
                reason: .timeout
            )
        case .malformedResponse:
            SharedErrorDescriptor(
                code: .structuredOutputInvalid,
                userMessage: "暂时无法处理服务响应，请重试。",
                subsystem: .provider,
                reason: .malformedResponse
            )
        case .schemaViolation:
            SharedErrorDescriptor(
                code: .toolArgumentsInvalid,
                userMessage: "请求参数暂时无法处理，请重试。",
                subsystem: .provider,
                reason: .schemaViolation
            )
        case .contentRejected:
            SharedErrorDescriptor(
                code: .providerUnavailable,
                userMessage: "本次内容暂时无法处理。",
                subsystem: .provider,
                reason: .contentRejected
            )
        case .unsupportedCapability:
            SharedErrorDescriptor(
                code: .providerUnavailable,
                userMessage: "当前 AI 服务暂不支持该能力。",
                subsystem: .provider,
                reason: .unsupportedCapability
            )
        case .cancelled:
            SharedErrorDescriptor(
                code: .providerUnavailable,
                userMessage: "请求已取消。",
                subsystem: .provider,
                reason: .cancelled
            )
        case .budgetExceeded:
            SharedErrorDescriptor(
                code: .providerUnavailable,
                userMessage: "本次请求处理预算已用尽。",
                subsystem: .provider,
                reason: .budgetExceeded
            )
        case .budgetUnavailable:
            SharedErrorDescriptor(
                code: .providerUnavailable,
                userMessage: "无法验证当前模型的价格预算，已停止本次云端请求；请检查模型和价格配置后重试。",
                subsystem: .provider,
                reason: .budgetExceeded
            )
        }
    }

    var errorDescription: String? {
        sharedErrorDescriptor.userMessage
    }
}
