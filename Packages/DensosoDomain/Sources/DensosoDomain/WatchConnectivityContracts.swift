import Foundation

public struct WatchMessageEnvelope: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let messageID: UUID
    public let createdAt: Date
    /// Commands expire before they can be replayed as stale user intent.
    /// Optional remains decodable for schema-1 messages from earlier releases.
    public let expiresAt: Date?
    /// Positive sequence assigned to a new Watch command; nil preserves legacy arrival ordering.
    public let causalSequence: Int?
    /// The earlier causal sequence that must finish successfully before this command executes.
    public let dependsOn: Int?
    public let payload: WatchPayload

    public var id: UUID { messageID }

    public init(
        schemaVersion: Int = currentSchemaVersion,
        messageID: UUID = UUID(),
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        causalSequence: Int? = nil,
        dependsOn: Int? = nil,
        payload: WatchPayload
    ) {
        self.schemaVersion = schemaVersion
        self.messageID = messageID
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? WatchMessageExpiryPolicy.expirationDate(for: payload, createdAt: createdAt)
        self.causalSequence = causalSequence
        self.dependsOn = dependsOn
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

/// A Watch-safe projection of next-day guidance. Evidence is not sent to Watch;
/// empty `reasons` remains present for decoding by older Watch app versions.
public struct WatchTomorrowGuidanceSummary: Codable, Equatable, Sendable {
    public let expectedState: NextDayState
    public let confidence: EstimateConfidence
    public let reasons: [EvidenceReference]
    public let recommendedAction: RecommendationAction
    public let conditionalNote: String

    public init(
        expectedState: NextDayState,
        confidence: EstimateConfidence,
        recommendedAction: RecommendationAction,
        conditionalNote: String
    ) {
        self.expectedState = expectedState
        self.confidence = confidence
        self.reasons = []
        self.recommendedAction = recommendedAction
        self.conditionalNote = conditionalNote
    }

    private enum CodingKeys: String, CodingKey {
        case expectedState
        case confidence
        case reasons
        case recommendedAction
        case conditionalNote
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expectedState = try container.decode(NextDayState.self, forKey: .expectedState)
        confidence = try container.decode(EstimateConfidence.self, forKey: .confidence)
        // Consume but discard evidence keys from old full-guidance payloads.
        _ = try container.decodeIfPresent([EvidenceReference].self, forKey: .reasons)
        reasons = []
        recommendedAction = try container.decode(RecommendationAction.self, forKey: .recommendedAction)
        conditionalNote = try container.decode(String.self, forKey: .conditionalNote)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expectedState, forKey: .expectedState)
        try container.encode(confidence, forKey: .confidence)
        try container.encode([EvidenceReference](), forKey: .reasons)
        try container.encode(recommendedAction, forKey: .recommendedAction)
        try container.encode(conditionalNote, forKey: .conditionalNote)
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
    /// Optional to keep snapshots encoded by older iPhone versions decodable.
    public let recoverySummary: WatchRecoverySummary?
    /// Optional to keep snapshots encoded by older iPhone versions decodable.
    public let tomorrowGuidance: WatchTomorrowGuidanceSummary?
    public let domains: [WatchHealthDomainStatus]
    public let pendingActions: [WatchPendingActionSummary]
    public let workoutPlans: [WatchWorkoutPlanSummary]
    /// Message IDs whose receipt reached a processed/rejected terminal state.
    public let acknowledgedMessageIDs: [UUID]
    /// Every causal sequence from 1 through this value has only terminal receipts.
    /// Optional to preserve decoding for schemaVersion 1 snapshots from older phones.
    public let terminalCausalSequenceWatermark: Int?

    public init(
        generatedAt: Date = Date(),
        summary: String,
        domains: [WatchHealthDomainStatus],
        pendingActions: [WatchPendingActionSummary],
        workoutPlans: [WatchWorkoutPlanSummary] = [],
        acknowledgedMessageIDs: [UUID],
        terminalCausalSequenceWatermark: Int? = nil,
        tomorrowGuidance: WatchTomorrowGuidanceSummary? = nil,
        recoverySummary: WatchRecoverySummary? = nil
    ) {
        self.generatedAt = generatedAt
        self.summary = String(summary.prefix(500))
        self.recoverySummary = recoverySummary
        self.tomorrowGuidance = tomorrowGuidance
        self.domains = domains
        self.pendingActions = Array(pendingActions.prefix(10))
        self.workoutPlans = Array(workoutPlans.prefix(10))
        self.acknowledgedMessageIDs = Array(acknowledgedMessageIDs.suffix(100))
        self.terminalCausalSequenceWatermark = terminalCausalSequenceWatermark
    }

    public func isCurrentLocalDay(asOf date: Date, calendar: Calendar) -> Bool {
        calendar.startOfDay(for: generatedAt) == calendar.startOfDay(for: date)
    }

    public func activePendingActions(asOf date: Date) -> [WatchPendingActionSummary] {
        pendingActions.filter { $0.expiresAt > date }
    }
}

public enum WatchMessageError: Equatable, Sendable, SharedErrorDescribing {
    case unsupportedSchemaVersion(Int)
    case emptyTranscript
    case transcriptTooLong
    case messageIDCollision(UUID)
    case invalidCausalSequence
    case invalidCausalDependency
    case causalSequenceExhausted
    case outboxCapacityExceeded
    case invalidExpiry

    public var sharedErrorDescriptor: SharedErrorDescriptor {
        let reason: SharedErrorReason
        let numericCode: Int?
        switch self {
        case .unsupportedSchemaVersion(let version):
            reason = .watchUnsupportedSchema
            numericCode = version
        case .emptyTranscript:
            reason = .watchEmptyTranscript
            numericCode = nil
        case .transcriptTooLong:
            reason = .watchTranscriptTooLong
            numericCode = nil
        case .messageIDCollision:
            reason = .watchMessageIDCollision
            numericCode = nil
        case .invalidCausalSequence:
            reason = .watchInvalidCausalSequence
            numericCode = nil
        case .invalidCausalDependency:
            reason = .watchInvalidCausalDependency
            numericCode = nil
        case .causalSequenceExhausted:
            reason = .watchCausalSequenceExhausted
            numericCode = nil
        case .outboxCapacityExceeded:
            reason = .watchOutboxFull
            numericCode = nil
        case .invalidExpiry:
            reason = .watchInvalidExpiry
            numericCode = nil
        }
        return SharedErrorDescriptor(
            code: .watchUnavailable,
            userMessage: "暂时无法同步 Apple Watch 数据。",
            subsystem: .watch,
            reason: reason,
            numericCode: numericCode
        )
    }
}

public enum WatchMessageExpiryPolicy {
    public static let orderedCommandLifetime: TimeInterval = 24 * 60 * 60
    public static let snapshotRequestLifetime: TimeInterval = 15 * 60
    public static let maximumFutureClockSkew: TimeInterval = 5 * 60

    public static func expirationDate(for payload: WatchPayload, createdAt: Date) -> Date? {
        let lifetime: TimeInterval
        switch payload {
        case .transcript, .confirm, .reject:
            lifetime = orderedCommandLifetime
        case .requestTodaySnapshot:
            lifetime = snapshotRequestLifetime
        case .acknowledgement, .todaySnapshot:
            return nil
        }
        return createdAt.addingTimeInterval(lifetime)
    }

    public static func isExpired(_ envelope: WatchMessageEnvelope, asOf date: Date) -> Bool {
        guard envelope.createdAt <= date.addingTimeInterval(maximumFutureClockSkew) else { return true }
        guard let expiresAt = envelope.expiresAt
                ?? expirationDate(for: envelope.payload, createdAt: envelope.createdAt) else { return false }
        return expiresAt <= date
    }
}

public enum WatchMessageAuthorizationPolicy {
    /// Watch can submit quick records, but pending actions must be reviewed on iPhone.
    public static func requiresPhoneConfirmation(for payload: WatchPayload) -> Bool {
        switch payload {
        case .confirm, .reject:
            true
        case .transcript, .requestTodaySnapshot, .acknowledgement, .todaySnapshot:
            false
        }
    }
}

public struct WatchMessageOutbox: Codable, Equatable, Sendable {
    public static let maximumPendingMessageCount = 128

    private var pendingByID: [UUID: WatchMessageEnvelope]
    private var lastCausalSequence: Int?

    public init(pending: [WatchMessageEnvelope] = []) {
        self.pendingByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.messageID, $0) })
        self.lastCausalSequence = pending.compactMap(\.causalSequence).max()
    }

    public var latestCausalSequence: Int? {
        let latest = max(lastCausalSequence ?? 0, pendingByID.values.compactMap(\.causalSequence).max() ?? 0)
        return latest > 0 ? latest : nil
    }

    /// The last command that still needs a terminal phone receipt, if any.
    /// New independent commands must not inherit a rejected historical dependency.
    public var latestPendingCausalSequence: Int? {
        pendingByID.values.compactMap(\.causalSequence).max()
    }

    @discardableResult
    public mutating func enqueue(_ envelope: WatchMessageEnvelope) throws -> Bool {
        try WatchMessageCodec.validate(envelope)
        if let existing = pendingByID[envelope.messageID] {
            guard existing == envelope else { throw WatchMessageError.messageIDCollision(envelope.messageID) }
            return false
        }
        guard pendingByID.count < Self.maximumPendingMessageCount else {
            throw WatchMessageError.outboxCapacityExceeded
        }
        pendingByID[envelope.messageID] = envelope
        if let causalSequence = envelope.causalSequence {
            lastCausalSequence = max(lastCausalSequence ?? 0, causalSequence)
        }
        return true
    }

    public mutating func enqueueCausalCommand(
        _ payload: WatchPayload,
        dependsOn: Int? = nil,
        messageID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> WatchMessageEnvelope {
        let previousSequence = latestCausalSequence ?? 0
        guard previousSequence < Int.max else { throw WatchMessageError.causalSequenceExhausted }
        let envelope = WatchMessageEnvelope(
            messageID: messageID,
            createdAt: createdAt,
            causalSequence: previousSequence + 1,
            dependsOn: dependsOn,
            payload: payload
        )
        _ = try enqueue(envelope)
        return envelope
    }

    public mutating func acknowledge(_ acknowledgement: WatchAcknowledgement) {
        switch acknowledgement.state {
        // Persisted acceptance is terminal for legacy envelopes only. Sequenced
        // commands remain queued until their receipt reaches a terminal state.
        case .accepted, .processed, .duplicate, .rejected:
            if acknowledgement.state != .accepted
                || pendingByID[acknowledgement.messageID]?.causalSequence == nil {
                pendingByID.removeValue(forKey: acknowledgement.messageID)
            }
        }
    }

    public mutating func acknowledge(messageIDs: [UUID]) {
        for id in messageIDs { pendingByID.removeValue(forKey: id) }
    }

    /// Removes only sequenced commands whose terminal receipts are covered by
    /// the phone's contiguous watermark. Legacy commands have no sequence and
    /// continue to rely on their per-message IDs.
    @discardableResult
    public mutating func acknowledge(throughCausalSequence watermark: Int) -> [UUID] {
        guard watermark > 0 else { return [] }
        let acknowledgedIDs = pendingByID.values.compactMap { envelope -> UUID? in
            guard let sequence = envelope.causalSequence, sequence <= watermark else { return nil }
            return envelope.messageID
        }
        for id in acknowledgedIDs { pendingByID.removeValue(forKey: id) }
        return acknowledgedIDs
    }

    public var pending: [WatchMessageEnvelope] {
        WatchCommandOrderingPolicy.dispatchOrder(Array(pendingByID.values))
    }

    private enum CodingKeys: String, CodingKey {
        case pendingByID
        case lastCausalSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pendingByID = try container.decode([UUID: WatchMessageEnvelope].self, forKey: .pendingByID)
        guard pendingByID.count <= Self.maximumPendingMessageCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .pendingByID,
                in: container,
                debugDescription: "Watch outbox exceeds its pending-message limit."
            )
        }
        for (key, envelope) in pendingByID {
            guard key == envelope.messageID else {
                throw DecodingError.dataCorruptedError(
                    forKey: .pendingByID,
                    in: container,
                    debugDescription: "Watch outbox keys must match message identifiers."
                )
            }
            do {
                try WatchMessageCodec.validate(envelope)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .pendingByID,
                    in: container,
                    debugDescription: "Watch outbox contains an invalid message envelope."
                )
            }
        }
        let lastCausalSequence = try container.decodeIfPresent(Int.self, forKey: .lastCausalSequence)
        guard lastCausalSequence.map({ $0 >= 0 }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .lastCausalSequence,
                in: container,
                debugDescription: "Watch outbox causal sequence cannot be negative."
            )
        }
        self.pendingByID = pendingByID
        self.lastCausalSequence = lastCausalSequence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pendingByID, forKey: .pendingByID)
        try container.encodeIfPresent(lastCausalSequence, forKey: .lastCausalSequence)
    }
}

public enum WatchMessageCodec {
    public static let maximumTranscriptLength = 4_000
    public static let maximumTranscriptUTF8Bytes = 32_000

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
        guard (1...WatchMessageEnvelope.currentSchemaVersion).contains(envelope.schemaVersion) else {
            throw WatchMessageError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard envelope.createdAt.timeIntervalSince1970.isFinite else {
            throw WatchMessageError.invalidExpiry
        }
        let maximumExpiry = WatchMessageExpiryPolicy.expirationDate(
            for: envelope.payload,
            createdAt: envelope.createdAt
        )
        if let expiresAt = envelope.expiresAt {
            guard expiresAt.timeIntervalSince1970.isFinite,
                  expiresAt > envelope.createdAt,
                  maximumExpiry.map({ expiresAt <= $0 }) ?? true else {
                throw WatchMessageError.invalidExpiry
            }
        }
        if envelope.schemaVersion >= 2, maximumExpiry != nil, envelope.expiresAt == nil {
            throw WatchMessageError.invalidExpiry
        }
        if let causalSequence = envelope.causalSequence {
            guard causalSequence > 0 else { throw WatchMessageError.invalidCausalSequence }
            switch envelope.payload {
            case .transcript, .confirm, .reject:
                break
            case .requestTodaySnapshot, .acknowledgement, .todaySnapshot:
                throw WatchMessageError.invalidCausalSequence
            }
        }
        if let dependsOn = envelope.dependsOn {
            guard dependsOn > 0,
                  let causalSequence = envelope.causalSequence,
                  dependsOn < causalSequence else {
                throw WatchMessageError.invalidCausalDependency
            }
        }
        if case .transcript(let text) = envelope.payload {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { throw WatchMessageError.emptyTranscript }
            guard normalized.count <= maximumTranscriptLength,
                  normalized.utf8.count <= maximumTranscriptUTF8Bytes else {
                throw WatchMessageError.transcriptTooLong
            }
        }
    }
}
