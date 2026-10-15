import Foundation

enum ProviderError: LocalizedError, Equatable, Sendable {
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

    var errorDescription: String? {
        switch self {
        case .configurationMissing(let provider): "\(provider.rawValue) 尚未配置"
        case .consentRequired: "需要先同意本次云端数据上传"
        case .unauthorized: "Provider 凭据无效或无权限"
        case .quotaExhausted: "Provider 配额不可用"
        case .rateLimited: "Provider 请求过于频繁，请稍后重试"
        case .requestRejected: "Provider 拒绝了本次请求格式"
        case .requestTooLarge(let limitBytes): "会话过长，请清空对话后重试（本地上限 \(limitBytes) bytes）"
        case .server: "Provider 服务暂时不可用"
        case .network: "网络连接失败"
        case .timeout: "Provider 请求超过总时限"
        case .malformedResponse: "Provider 返回格式异常"
        case .schemaViolation(let path): "工具参数不符合本地 Schema：\(path)"
        case .contentRejected: "Provider 拒绝处理该内容"
        case .unsupportedCapability: "当前 Provider 不支持此能力"
        case .cancelled: "请求已取消"
        case .budgetExceeded: "本次 Agent 预算已用尽"
        }
    }
}
