import Foundation

/// Stable top-level classifications shared by app, domain, and Watch boundaries.
public enum SharedErrorCode: String, Codable, CaseIterable, Sendable {
    case networkUnavailable = "NetworkUnavailable"
    case providerUnauthorized = "ProviderUnauthorized"
    case providerRateLimited = "ProviderRateLimited"
    case providerUnavailable = "ProviderUnavailable"
    case structuredOutputInvalid = "StructuredOutputInvalid"
    case toolArgumentsInvalid = "ToolArgumentsInvalid"
    case healthKitUnauthorized = "HealthKitUnauthorized"
    case healthKitUnavailable = "HealthKitUnavailable"
    case projectionFailed = "ProjectionFailed"
    case confirmationExpired = "ConfirmationExpired"
    case actionConflict = "ActionConflict"
    case watchUnavailable = "WatchUnavailable"
    case workoutKitUnauthorized = "WorkoutKitUnauthorized"
}

/// A controlled subsystem value used to keep diagnostic detail free of raw errors.
public enum SharedErrorSubsystem: String, Codable, CaseIterable, Sendable {
    case provider
    case healthKit
    case projection
    case confirmation
    case watch
    case workoutKit
    case agent
}

/// Stable, allowlisted reason values. Never put user content or an underlying
/// error's localized description in this enum or in a diagnostic descriptor.
public enum SharedErrorReason: String, Codable, CaseIterable, Sendable {
    case configurationMissing
    case consentRequired
    case unauthorized
    case quotaExhausted
    case rateLimited
    case requestRejected
    case requestModelMismatch
    case requestTooLarge
    case serverFailure
    case networkFailure
    case timeout
    case malformedResponse
    case schemaViolation
    case contentRejected
    case unsupportedCapability
    case cancelled
    case budgetExceeded
    case healthKitAuthorizationDenied
    case healthKitAuthorizationUndetermined
    case healthKitUnavailable
    case healthDataRestricted
    case healthDataLocked
    case unsupportedHealthMetric
    case invalidHealthKitAnchor
    case healthKitQueryFailed
    case missingHealthKitAnchor
    case refusedHealthKitEcho
    case dailyMetricsProjectionFailed
    case confirmationExpired
    case actionNotFound
    case actionRejected
    case actionAlreadyCommitting
    case confirmationPayloadCorrupt
    case persistenceReadOnly
    case unsupportedConfirmationAction
    case confirmationInvariantViolation
    case confirmationCommitFailed
    case watchUnavailable
    case watchProtocolViolation
    case unknownTool
    case invalidToolArguments
    case watchUnsupportedSchema
    case watchEmptyTranscript
    case watchTranscriptTooLong
    case watchMessageIDCollision
    case watchInvalidCausalSequence
    case watchInvalidCausalDependency
    case watchCausalSequenceExhausted
    case workoutKitAuthorizationDenied
    case workoutKitUnavailable
    case invalidWorkoutPlan
    case workoutPlanConflict
    case transientImageRequired
    case invalidInputEnvelope
    case agentEmptyResponse
    case requestAlreadyRunning
    case requestAlreadyCompleted
    case unsupportedToolSchemaVersion
}

/// A user-safe error classification with diagnostic context limited to enums
/// and an optional numeric platform/status code.
public struct SharedErrorDescriptor: Equatable, Sendable, LocalizedError {
    public let code: SharedErrorCode
    public let userMessage: String
    public let subsystem: SharedErrorSubsystem
    public let reason: SharedErrorReason
    public let numericCode: Int?

    public init(
        code: SharedErrorCode,
        userMessage: String,
        subsystem: SharedErrorSubsystem,
        reason: SharedErrorReason,
        numericCode: Int? = nil
    ) {
        self.code = code
        self.userMessage = userMessage
        self.subsystem = subsystem
        self.reason = reason
        self.numericCode = numericCode
    }

    public var diagnosticSafeDetail: String {
        var detail = "code=\(code.rawValue) subsystem=\(subsystem.rawValue) reason=\(reason.rawValue)"
        if let numericCode {
            detail += " numericCode=\(numericCode)"
        }
        return detail
    }

    public var errorDescription: String? { userMessage }
}

public protocol SharedErrorDescribing: LocalizedError {
    var sharedErrorDescriptor: SharedErrorDescriptor { get }
}

public extension SharedErrorDescribing {
    var errorDescription: String? { sharedErrorDescriptor.userMessage }
}

public extension SharedErrorDescriptor {
    static var healthKitUnavailableFallback: Self {
        Self(
            code: .healthKitUnavailable,
            userMessage: "暂时没能更新今天的状态。",
            subsystem: .healthKit,
            reason: .healthKitUnavailable
        )
    }

    static var providerUnavailableFallback: Self {
        Self(
            code: .providerUnavailable,
            userMessage: "AI 服务暂时不可用，请稍后重试。",
            subsystem: .provider,
            reason: .serverFailure
        )
    }

    static var projectionFailedFallback: Self {
        Self(
            code: .projectionFailed,
            userMessage: "暂时没能更新今天的状态。",
            subsystem: .projection,
            reason: .dailyMetricsProjectionFailed
        )
    }

    static var actionConflictFallback: Self {
        Self(
            code: .actionConflict,
            userMessage: "该操作暂时无法完成，请稍后重试。",
            subsystem: .confirmation,
            reason: .confirmationInvariantViolation
        )
    }

    static var watchUnavailableFallback: Self {
        Self(
            code: .watchUnavailable,
            userMessage: "暂时无法同步 Apple Watch 数据。",
            subsystem: .watch,
            reason: .watchUnavailable
        )
    }

    static var workoutKitUnavailableFallback: Self {
        Self(
            code: .watchUnavailable,
            userMessage: "Apple Watch 暂时无法安排训练计划。",
            subsystem: .workoutKit,
            reason: .workoutKitUnavailable
        )
    }

    static func mapped(from error: Error, fallback: Self) -> Self {
        (error as? any SharedErrorDescribing)?.sharedErrorDescriptor ?? fallback
    }
}
