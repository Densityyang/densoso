import Foundation

public struct WatchMessageEnvelope: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let messageID: UUID
    public let createdAt: Date
    public let payload: WatchPayload

    public var id: UUID { messageID }

    public init(
        schemaVersion: Int = currentSchemaVersion,
        messageID: UUID = UUID(),
        createdAt: Date = Date(),
        payload: WatchPayload
    ) {
        self.schemaVersion = schemaVersion
        self.messageID = messageID
        self.createdAt = createdAt
        self.payload = payload
    }
}

public enum WatchPayload: Codable, Equatable, Sendable {
    case transcript(String)
    case confirm(actionID: UUID)
    case reject(actionID: UUID)
    case requestTodaySnapshot
    case acknowledgement(WatchAcknowledgement)
    case todaySnapshot(WatchTodaySnapshot)
}

public enum WatchAcknowledgementState: String, Codable, CaseIterable, Sendable {
    case accepted
    case processed
    case duplicate
    case rejected
}

public struct WatchAcknowledgement: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let state: WatchAcknowledgementState
    public let detail: String?

    public init(messageID: UUID, state: WatchAcknowledgementState, detail: String? = nil) {
        self.messageID = messageID
        self.state = state
        self.detail = detail
    }
}

public struct WatchPendingActionSummary: Codable, Equatable, Identifiable, Sendable {
    public let actionID: UUID
    public let title: String
    public let summary: String
    public let expiresAt: Date
    /// Multi-day plans need the full session list, which the Watch summary intentionally omits.
    /// Optional keeps snapshots encoded by older app versions decodable.
    public let requiresPhoneReview: Bool?

    public var id: UUID { actionID }

    public init(
        actionID: UUID,
        title: String,
        summary: String,
        expiresAt: Date,
        requiresPhoneReview: Bool = false
    ) {
        self.actionID = actionID
        self.title = String(title.prefix(80))
        self.summary = String(summary.prefix(240))
        self.expiresAt = expiresAt
        self.requiresPhoneReview = requiresPhoneReview
    }
}

public struct WatchWorkoutPlanSummary: Codable, Equatable, Identifiable, Sendable {
    public let actionID: UUID
    public let title: String
    public let scheduledAt: Date?
    public let state: String
    public let lastError: String?

    public var id: UUID { actionID }

    public init(actionID: UUID, title: String, scheduledAt: Date?, state: String, lastError: String? = nil) {
        self.actionID = actionID
        self.title = String(title.prefix(80))
        self.scheduledAt = scheduledAt
        self.state = String(state.prefix(24))
        self.lastError = lastError.map { String($0.prefix(180)) }
    }
}

public struct WatchRecoverySummary: Codable, Equatable, Sendable {
    public let status: RecoveryStatus
    public let confidence: EstimateConfidence
    public let recommendedAction: RecommendationAction

    public init(
        status: RecoveryStatus,
        confidence: EstimateConfidence,
        recommendedAction: RecommendationAction
    ) {
        self.status = status
        self.confidence = confidence
        self.recommendedAction = recommendedAction
    }
}

/// A compact Watch projection that exposes a domain's state without sending
/// its numeric estimate, baseline, or evidence keys to the companion device.
public struct WatchHealthDomainStatus: Codable, Equatable, Sendable {
    public let domain: HealthDomain
    public let status: HealthDomainStatus

    public init(domain: HealthDomain, status: HealthDomainStatus) {
        self.domain = domain
        self.status = status
    }
}

/// A deliberately small, current-state-only snapshot for the Watch companion.
/// It never carries sample arrays, conversation history, or provider prompts.
public struct WatchTodaySnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let summary: String
    public let energyIntakeKcal: Int?
    public let totalExpenditureKcal: Int?
    public let deficitKcal: Int?
    /// Optional to keep snapshots encoded by older iPhone versions decodable.
    public let recoverySummary: WatchRecoverySummary?
    /// Optional to keep snapshots encoded by older iPhone versions decodable.
    public let tomorrowGuidance: NextDayGuidance?
    public let domains: [WatchHealthDomainStatus]
    public let pendingActions: [WatchPendingActionSummary]
    public let workoutPlans: [WatchWorkoutPlanSummary]
    /// Message IDs whose envelopes are durably stored on iPhone; their work may still be pending.
    public let acknowledgedMessageIDs: [UUID]

    public init(
        generatedAt: Date = Date(),
        summary: String,
        energyIntakeKcal: Int?,
        totalExpenditureKcal: Int?,
        deficitKcal: Int?,
        domains: [WatchHealthDomainStatus],
        pendingActions: [WatchPendingActionSummary],
        workoutPlans: [WatchWorkoutPlanSummary] = [],
        acknowledgedMessageIDs: [UUID],
        tomorrowGuidance: NextDayGuidance? = nil,
        recoverySummary: WatchRecoverySummary? = nil
    ) {
        self.generatedAt = generatedAt
        self.summary = String(summary.prefix(500))
        self.energyIntakeKcal = energyIntakeKcal.flatMap { $0 >= 0 ? $0 : nil }
        self.totalExpenditureKcal = totalExpenditureKcal.flatMap { $0 >= 0 ? $0 : nil }
        self.deficitKcal = deficitKcal
        self.recoverySummary = recoverySummary
        self.tomorrowGuidance = tomorrowGuidance
        self.domains = domains
        self.pendingActions = Array(pendingActions.prefix(10))
        self.workoutPlans = Array(workoutPlans.prefix(10))
        self.acknowledgedMessageIDs = Array(acknowledgedMessageIDs.suffix(100))
    }

    public func isCurrentLocalDay(asOf date: Date, calendar: Calendar) -> Bool {
        calendar.startOfDay(for: generatedAt) == calendar.startOfDay(for: date)
    }

    public func activePendingActions(asOf date: Date) -> [WatchPendingActionSummary] {
        pendingActions.filter { $0.expiresAt > date }
    }
}

public enum WatchMessageError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case emptyTranscript
    case transcriptTooLong
    case messageIDCollision(UUID)
}

public struct WatchMessageOutbox: Codable, Equatable, Sendable {
    private var pendingByID: [UUID: WatchMessageEnvelope]

    public init(pending: [WatchMessageEnvelope] = []) {
        self.pendingByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.messageID, $0) })
    }

    @discardableResult
    public mutating func enqueue(_ envelope: WatchMessageEnvelope) throws -> Bool {
        try WatchMessageCodec.validate(envelope)
        if let existing = pendingByID[envelope.messageID] {
            guard existing == envelope else { throw WatchMessageError.messageIDCollision(envelope.messageID) }
            return false
        }
        pendingByID[envelope.messageID] = envelope
        return true
    }

    public mutating func acknowledge(_ acknowledgement: WatchAcknowledgement) {
        switch acknowledgement.state {
        // `accepted` is emitted only after the phone persists a receipt.
        case .accepted, .processed, .duplicate, .rejected:
            pendingByID.removeValue(forKey: acknowledgement.messageID)
        }
    }

    public mutating func acknowledge(messageIDs: [UUID]) {
        for id in messageIDs { pendingByID.removeValue(forKey: id) }
    }

    public var pending: [WatchMessageEnvelope] {
        pendingByID.values.sorted {
            if $0.createdAt == $1.createdAt { return $0.messageID.uuidString < $1.messageID.uuidString }
            return $0.createdAt < $1.createdAt
        }
    }
}

public enum WatchMessageCodec {
    public static let maximumTranscriptLength = 4_000

    public static func encode(_ envelope: WatchMessageEnvelope) throws -> Data {
        try validate(envelope)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> WatchMessageEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(WatchMessageEnvelope.self, from: data)
        try validate(envelope)
        return envelope
    }

    public static func validate(_ envelope: WatchMessageEnvelope) throws {
        guard envelope.schemaVersion == WatchMessageEnvelope.currentSchemaVersion else {
            throw WatchMessageError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        if case .transcript(let text) = envelope.payload {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { throw WatchMessageError.emptyTranscript }
            guard normalized.count <= maximumTranscriptLength else { throw WatchMessageError.transcriptTooLong }
        }
    }
}
