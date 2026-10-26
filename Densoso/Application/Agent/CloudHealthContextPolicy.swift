import DensosoDomain
import CryptoKit
import Foundation

enum CloudHealthPolicyState: String, Codable, Sendable {
    case notConfigured
    case draft
    case active
    case revoked
    case needsReconfirmation
}

enum CloudHealthPolicyChangeSource: String, Codable, Sendable {
    case onboarding
    case settings
    case agentConversation
    case legacyConsent
    case backupRestore
}

struct CloudHealthContextPolicySnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let policyID: UUID
    let provider: ProviderID
    let revision: Int
    let state: CloudHealthPolicyState
    let allowedClasses: Set<ProviderDataClass>
    let createdAt: Date
    let updatedAt: Date
    let confirmedAt: Date?
    let policyHash: String
    let changeSource: CloudHealthPolicyChangeSource

    static func make(
        provider: ProviderID,
        policyID: UUID,
        revision: Int,
        state: CloudHealthPolicyState,
        allowedClasses: Set<ProviderDataClass>,
        createdAt: Date,
        updatedAt: Date,
        confirmedAt: Date?,
        changeSource: CloudHealthPolicyChangeSource
    ) -> Self {
        let canonical = [
            String(currentSchemaVersion),
            provider.rawValue,
            policyID.uuidString.lowercased(),
            String(max(revision, 0)),
            state.rawValue,
            allowedClasses.map(\.rawValue).sorted().joined(separator: ","),
            String(createdAt.timeIntervalSince1970),
            String(updatedAt.timeIntervalSince1970),
            confirmedAt.map { String($0.timeIntervalSince1970) } ?? "",
            changeSource.rawValue,
        ].joined(separator: "|")
        let hash = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return Self(
            schemaVersion: currentSchemaVersion,
            policyID: policyID,
            provider: provider,
            revision: max(revision, 0),
            state: state,
            allowedClasses: allowedClasses,
            createdAt: createdAt,
            updatedAt: updatedAt,
            confirmedAt: confirmedAt,
            policyHash: hash,
            changeSource: changeSource
        )
    }

    static func unconfigured(provider: ProviderID) -> Self {
        let policyID = stablePolicyID(for: provider)
        return make(
            provider: provider,
            policyID: policyID,
            revision: 0,
            state: .notConfigured,
            allowedClasses: [],
            createdAt: .distantPast,
            updatedAt: .distantPast,
            confirmedAt: nil,
            changeSource: .legacyConsent
        )
    }

    private static func stablePolicyID(for provider: ProviderID) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("cloud-health-policy|\(provider.rawValue)".utf8)).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

protocol CloudHealthContextPolicySnapshotRepository: Sendable {
    func currentCloudHealthContextPolicySnapshot(provider: ProviderID) async throws -> CloudHealthContextPolicySnapshot
    func withCurrentSendAuthorization<Result: Sendable>(
        provider: ProviderID,
        expectedSnapshot: CloudHealthContextPolicySnapshot,
        requiredClasses: Set<ProviderDataClass>,
        operation: @Sendable () throws -> Result
    ) async throws -> Result
    func stageCloudHealthContextPolicyDraft(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        changeSource: CloudHealthPolicyChangeSource
    ) async throws -> CloudHealthContextPolicySnapshot
    func updateConversationHistoryConsent(
        provider: ProviderID,
        allowed: Bool,
        changeSource: CloudHealthPolicyChangeSource,
        confirmedAt: Date?
    ) async throws -> CloudHealthContextPolicySnapshot
    func updateCloudHealthContextPolicy(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        changeSource: CloudHealthPolicyChangeSource,
        confirmedAt: Date?
    ) async throws -> CloudHealthContextPolicySnapshot
}

/// Provider-specific, opt-in permissions for historical health context.
/// Consent is stored in ProviderGovernanceRepository; a missing record is denied.
struct CloudHealthContextPolicy: Equatable, Sendable {
    static let dataClasses: [ProviderDataClass] = [
        .healthNutrition, .healthSleep, .healthActivity, .healthBody, .healthSubjective,
    ]

    let provider: ProviderID
    let allowedClasses: Set<ProviderDataClass>
    let allowsConversationHistory: Bool
    let snapshot: CloudHealthContextPolicySnapshot

    var revision: String {
        "\(provider.rawValue):\(snapshot.revision):\(snapshot.policyHash)"
    }

    /// This is a state fingerprint for request/cache invalidation, while
    /// `snapshot.revision` is the persisted monotonic change counter.
    init(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        allowsConversationHistory: Bool = false
    ) {
        self.provider = provider
        self.allowedClasses = allowedClasses.intersection(Set(Self.dataClasses))
        self.allowsConversationHistory = allowsConversationHistory
        let effectiveClasses = allowedClasses.intersection(Set(Self.dataClasses))
        self.snapshot = Self.snapshotForRead(provider: provider, allowedClasses: effectiveClasses)
    }

    private init(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        allowsConversationHistory: Bool,
        snapshot: CloudHealthContextPolicySnapshot
    ) {
        self.provider = provider
        self.allowedClasses = allowedClasses.intersection(Set(Self.dataClasses))
        self.allowsConversationHistory = allowsConversationHistory
        self.snapshot = snapshot
    }

    func allows(_ dataClass: ProviderDataClass) -> Bool {
        allowedClasses.contains(dataClass)
    }

    var allowsDerivedRecovery: Bool {
        allows(.healthSleep) && allows(.healthActivity) && allows(.healthBody)
    }

    static func load(from repository: any ProviderGovernanceRepository, provider: ProviderID) async throws -> Self {
        let firstPolicySnapshot: CloudHealthContextPolicySnapshot?
        let secondPolicySnapshot: CloudHealthContextPolicySnapshot?
        if let policyRepository = repository as? any CloudHealthContextPolicySnapshotRepository {
            firstPolicySnapshot = try await policyRepository.currentCloudHealthContextPolicySnapshot(provider: provider)
            secondPolicySnapshot = try await policyRepository.currentCloudHealthContextPolicySnapshot(provider: provider)
        } else {
            firstPolicySnapshot = nil
            secondPolicySnapshot = nil
        }
        let firstSnapshot = try await consentSnapshot(from: repository, provider: provider, classes: dataClasses)
        let secondSnapshot = try await consentSnapshot(from: repository, provider: provider, classes: dataClasses)
        let firstHistoryConsent = try await repository.isConsentGranted(provider: provider, dataClass: .conversationHistory)
        let secondHistoryConsent = try await repository.isConsentGranted(provider: provider, dataClass: .conversationHistory)
        // If consent changes during the asynchronous reads, prefer the class that was denied in either pass.
        let persistedClasses: Set<ProviderDataClass>?
        if firstPolicySnapshot?.state == .active, secondPolicySnapshot?.state == .active {
            persistedClasses = firstPolicySnapshot?.allowedClasses.intersection(
                secondPolicySnapshot?.allowedClasses ?? []
            )
        } else if firstPolicySnapshot != nil || secondPolicySnapshot != nil {
            persistedClasses = []
        } else {
            persistedClasses = nil
        }
        let repositoryClasses = firstSnapshot.intersection(secondSnapshot)
        let allowed = persistedClasses.map { $0.intersection(repositoryClasses) } ?? repositoryClasses
        let snapshot = secondPolicySnapshot ?? Self.snapshotForRead(provider: provider, allowedClasses: allowed)
        let snapshotAllowsConversationHistory: Bool
        if let firstPolicySnapshot, let secondPolicySnapshot {
            snapshotAllowsConversationHistory = firstPolicySnapshot.state == .active
                && secondPolicySnapshot.state == .active
                && firstPolicySnapshot.allowedClasses.contains(.conversationHistory)
                && secondPolicySnapshot.allowedClasses.contains(.conversationHistory)
        } else {
            snapshotAllowsConversationHistory = true
        }
        return Self(
            provider: provider,
            allowedClasses: allowed,
            allowsConversationHistory: firstHistoryConsent
                && secondHistoryConsent
                && snapshotAllowsConversationHistory,
            snapshot: snapshot
        )
    }

    static func applyRestrictiveChange(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        repository: any ProviderGovernanceRepository,
        changeSource: CloudHealthPolicyChangeSource = .agentConversation
    ) async throws -> CloudHealthContextPolicySnapshot {
        try await persist(
            provider: provider,
            allowedClasses: allowedClasses,
            repository: repository,
            changeSource: changeSource,
            confirmedExpansion: false
        )
    }

    static func confirmExpandedPolicy(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        repository: any ProviderGovernanceRepository,
        confirmedAt: Date = Date(),
        changeSource: CloudHealthPolicyChangeSource = .agentConversation
    ) async throws -> CloudHealthContextPolicySnapshot {
        try await persist(
            provider: provider,
            allowedClasses: allowedClasses,
            repository: repository,
            changeSource: changeSource,
            confirmedExpansion: true,
            confirmedAt: confirmedAt
        )
    }

    static func updateConversationHistoryConsent(
        provider: ProviderID,
        allowed: Bool,
        repository: any ProviderGovernanceRepository,
        confirmedAt: Date? = nil,
        changeSource: CloudHealthPolicyChangeSource = .settings
    ) async throws -> CloudHealthContextPolicySnapshot {
        let first = try await repository.isConsentGranted(provider: provider, dataClass: .conversationHistory)
        let second = try await repository.isConsentGranted(provider: provider, dataClass: .conversationHistory)
        guard !allowed || (first && second) || confirmedAt != nil else {
            throw CloudHealthContextPolicyError.expansionRequiresConfirmation
        }
        if let snapshotRepository = repository as? any CloudHealthContextPolicySnapshotRepository {
            return try await snapshotRepository.updateConversationHistoryConsent(
                provider: provider,
                allowed: allowed,
                changeSource: changeSource,
                confirmedAt: confirmedAt
            )
        }
        try await repository.setConsent(
            provider: provider,
            dataClass: .conversationHistory,
            granted: allowed,
            policyVersion: "cloud-conversation-history-v1"
        )
        return try await currentSnapshotForConsent(from: repository, provider: provider)
    }

    private static func currentSnapshotForConsent(
        from repository: any ProviderGovernanceRepository,
        provider: ProviderID
    ) async throws -> CloudHealthContextPolicySnapshot {
        if let snapshotRepository = repository as? any CloudHealthContextPolicySnapshotRepository {
            return try await snapshotRepository.currentCloudHealthContextPolicySnapshot(provider: provider)
        }
        return snapshotForRead(
            provider: provider,
            allowedClasses: try await consentSnapshot(from: repository, provider: provider, classes: dataClasses)
        )
    }

    static func stageConversationExpansion(
        provider: ProviderID,
        requestedClasses: Set<ProviderDataClass>,
        repository: any ProviderGovernanceRepository
    ) async throws -> CloudHealthContextPolicySnapshot {
        guard let snapshotRepository = repository as? any CloudHealthContextPolicySnapshotRepository else {
            throw CloudHealthContextPolicyError.snapshotRepositoryUnavailable
        }
        let current = try await load(from: repository, provider: provider)
        let target = current.snapshot.allowedClasses.union(requestedClasses.intersection(Set(dataClasses)))
        guard !target.subtracting(current.snapshot.allowedClasses).isEmpty else {
            return current.snapshot
        }
        return try await snapshotRepository.stageCloudHealthContextPolicyDraft(
            provider: provider,
            allowedClasses: target,
            changeSource: .agentConversation
        )
    }

    static func confirmPendingConversationExpansion(
        provider: ProviderID,
        repository: any ProviderGovernanceRepository,
        confirmedAt: Date = Date()
    ) async throws -> CloudHealthContextPolicySnapshot {
        guard let snapshotRepository = repository as? any CloudHealthContextPolicySnapshotRepository else {
            throw CloudHealthContextPolicyError.snapshotRepositoryUnavailable
        }
        let draft = try await snapshotRepository.currentCloudHealthContextPolicySnapshot(provider: provider)
        guard draft.state == .draft else {
            throw CloudHealthContextPolicyError.noPendingExpansion
        }
        return try await confirmExpandedPolicy(
            provider: provider,
            allowedClasses: draft.allowedClasses,
            repository: repository,
            confirmedAt: confirmedAt,
            changeSource: .agentConversation
        )
    }

    static func cancelPendingConversationExpansion(
        provider: ProviderID,
        repository: any ProviderGovernanceRepository
    ) async throws -> CloudHealthContextPolicySnapshot {
        guard let snapshotRepository = repository as? any CloudHealthContextPolicySnapshotRepository else {
            throw CloudHealthContextPolicyError.snapshotRepositoryUnavailable
        }
        let draft = try await snapshotRepository.currentCloudHealthContextPolicySnapshot(provider: provider)
        guard draft.state == .draft else {
            throw CloudHealthContextPolicyError.noPendingExpansion
        }
        // Consent records are deliberately untouched while a draft is pending;
        // intersect reads twice before restoring their previously active set.
        let before = try await consentSnapshot(from: repository, provider: provider, classes: dataClasses)
        let after = try await consentSnapshot(from: repository, provider: provider, classes: dataClasses)
        let retainedClasses = before.intersection(after)
        return try await snapshotRepository.updateCloudHealthContextPolicy(
            provider: provider,
            allowedClasses: retainedClasses,
            changeSource: .agentConversation,
            confirmedAt: nil
        )
    }

    private static func persist(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        repository: any ProviderGovernanceRepository,
        changeSource: CloudHealthPolicyChangeSource,
        confirmedExpansion: Bool,
        confirmedAt: Date? = nil
    ) async throws -> CloudHealthContextPolicySnapshot {
        let allowed = allowedClasses.intersection(Set(dataClasses))
        let current = try await load(from: repository, provider: provider)
        let additions = allowed.subtracting(current.allowedClasses)
        guard additions.isEmpty || confirmedExpansion else {
            throw CloudHealthContextPolicyError.expansionRequiresConfirmation
        }
        if let snapshotRepository = repository as? any CloudHealthContextPolicySnapshotRepository {
            return try await snapshotRepository.updateCloudHealthContextPolicy(
                provider: provider,
                allowedClasses: allowed,
                changeSource: changeSource,
                confirmedAt: additions.isEmpty ? current.snapshot.confirmedAt : confirmedAt
            )
        }
        for dataClass in dataClasses {
            try await repository.setConsent(
                provider: provider,
                dataClass: dataClass,
                granted: allowed.contains(dataClass),
                policyVersion: "cloud-health-context-v1"
            )
        }
        return snapshotForRead(provider: provider, allowedClasses: allowed)
    }

    private static func snapshotForRead(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>
    ) -> CloudHealthContextPolicySnapshot {
        CloudHealthContextPolicySnapshot.make(
            provider: provider,
            policyID: CloudHealthContextPolicySnapshot.unconfigured(provider: provider).policyID,
            revision: 0,
            state: allowedClasses.isEmpty ? .notConfigured : .active,
            allowedClasses: allowedClasses,
            createdAt: .distantPast,
            updatedAt: .distantPast,
            confirmedAt: nil,
            changeSource: .legacyConsent
        )
    }

    /// Runs a send-start or retry gate after the final conservative consent read.
    static func withCurrentSendConsent<Result: Sendable>(
        from repository: any ProviderGovernanceRepository,
        provider: ProviderID,
        expectedHealthPolicy: Self,
        includesImage: Bool,
        requiresHealthText: Bool = true,
        additionalRequiredClasses: Set<ProviderDataClass> = [],
        operation: @Sendable () throws -> Result
    ) async throws -> Result {
        if let snapshotRepository = repository as? any CloudHealthContextPolicySnapshotRepository {
            guard expectedHealthPolicy.provider == provider,
                  expectedHealthPolicy.snapshot.provider == provider else {
                throw ProviderError.consentPolicyChanged(provider: provider)
            }
            return try await snapshotRepository.withCurrentSendAuthorization(
                provider: provider,
                expectedSnapshot: expectedHealthPolicy.snapshot,
                requiredClasses: currentSendRequiredClasses(
                    expectedHealthPolicy: expectedHealthPolicy,
                    includesImage: includesImage,
                    requiresHealthText: requiresHealthText,
                    additionalRequiredClasses: additionalRequiredClasses
                ),
                operation: operation
            )
        }
        try await validateCurrentSendConsent(
            from: repository,
            provider: provider,
            expectedHealthPolicy: expectedHealthPolicy,
            includesImage: includesImage,
            requiresHealthText: requiresHealthText,
            additionalRequiredClasses: additionalRequiredClasses
        )
        return try operation()
    }

    /// Executes serialization on the governance actor after an atomic policy
    /// revision and consent check, so revocation cannot interleave with payload
    /// encoding.
    static func withCurrentSendConsentSerialization<Result: Sendable>(
        from repository: any ProviderGovernanceRepository,
        provider: ProviderID,
        expectedHealthPolicy: Self,
        includesImage: Bool,
        requiresHealthText: Bool = true,
        operation: @Sendable () throws -> Result
    ) async throws -> Result {
        if let snapshotRepository = repository as? any CloudHealthContextPolicySnapshotRepository {
            guard expectedHealthPolicy.provider == provider,
                  expectedHealthPolicy.snapshot.provider == provider else {
                throw ProviderError.consentPolicyChanged(provider: provider)
            }
            return try await snapshotRepository.withCurrentSendAuthorization(
                provider: provider,
                expectedSnapshot: expectedHealthPolicy.snapshot,
                requiredClasses: currentSendRequiredClasses(
                    expectedHealthPolicy: expectedHealthPolicy,
                    includesImage: includesImage,
                    requiresHealthText: requiresHealthText
                ),
                operation: operation
            )
        }
        try await validateCurrentSendConsent(
            from: repository,
            provider: provider,
            expectedHealthPolicy: expectedHealthPolicy,
            includesImage: includesImage,
            requiresHealthText: requiresHealthText
        )
        return try operation()
    }

    static func validateCurrentSendConsent(
        from repository: any ProviderGovernanceRepository,
        provider: ProviderID,
        expectedHealthPolicy: Self,
        includesImage: Bool,
        requiresHealthText: Bool = true,
        additionalRequiredClasses: Set<ProviderDataClass> = []
    ) async throws {
        guard expectedHealthPolicy.provider == provider,
              expectedHealthPolicy.snapshot.provider == provider else {
            throw ProviderError.consentPolicyChanged(provider: provider)
        }
        let classes = Array(currentSendRequiredClasses(
            expectedHealthPolicy: expectedHealthPolicy,
            includesImage: includesImage,
            requiresHealthText: requiresHealthText,
            additionalRequiredClasses: additionalRequiredClasses
        )).sorted { $0.rawValue < $1.rawValue }
        let firstSnapshot = try await consentSnapshot(from: repository, provider: provider, classes: classes)
        let secondSnapshot = try await consentSnapshot(from: repository, provider: provider, classes: classes)
        let current = firstSnapshot.intersection(secondSnapshot)

        if requiresHealthText, !current.contains(.healthText) {
            throw ProviderError.consentRequired(provider: provider, dataClass: .healthText)
        }
        if includesImage, !current.contains(.mealImage) {
            throw ProviderError.consentRequired(provider: provider, dataClass: .mealImage)
        }
        if expectedHealthPolicy.allowsConversationHistory, !current.contains(.conversationHistory) {
            throw ProviderError.consentRequired(provider: provider, dataClass: .conversationHistory)
        }
        for dataClass in additionalRequiredClasses.sorted(by: { $0.rawValue < $1.rawValue })
        where !current.contains(dataClass) {
            throw ProviderError.consentRequired(provider: provider, dataClass: dataClass)
        }
        let currentHealthClasses = current.intersection(Set(dataClasses))
        guard currentHealthClasses.isSuperset(of: expectedHealthPolicy.allowedClasses) else {
            let revokedClass = expectedHealthPolicy.allowedClasses.subtracting(currentHealthClasses)
                .sorted { $0.rawValue < $1.rawValue }.first ?? .healthText
            throw ProviderError.consentRequired(provider: provider, dataClass: revokedClass)
        }
        if let snapshotRepository = repository as? any CloudHealthContextPolicySnapshotRepository {
            let firstPolicySnapshot = try await snapshotRepository.currentCloudHealthContextPolicySnapshot(
                provider: provider
            )
            let secondPolicySnapshot = try await snapshotRepository.currentCloudHealthContextPolicySnapshot(
                provider: provider
            )
            guard expectedHealthPolicy.provider == provider,
                  expectedHealthPolicy.snapshot.provider == provider,
                  firstPolicySnapshot == expectedHealthPolicy.snapshot,
                  secondPolicySnapshot == expectedHealthPolicy.snapshot else {
                throw ProviderError.consentPolicyChanged(provider: provider)
            }
        }
    }

    private static func currentSendRequiredClasses(
        expectedHealthPolicy: Self,
        includesImage: Bool,
        requiresHealthText: Bool,
        additionalRequiredClasses: Set<ProviderDataClass> = []
    ) -> Set<ProviderDataClass> {
        var required = expectedHealthPolicy.allowedClasses
        if requiresHealthText { required.insert(.healthText) }
        if expectedHealthPolicy.allowsConversationHistory { required.insert(.conversationHistory) }
        if includesImage { required.insert(.mealImage) }
        required.formUnion(additionalRequiredClasses)
        return required
    }

    private static func consentSnapshot(
        from repository: any ProviderGovernanceRepository,
        provider: ProviderID,
        classes: [ProviderDataClass]
    ) async throws -> Set<ProviderDataClass> {
        var allowed = Set<ProviderDataClass>()
        for dataClass in classes {
            if try await repository.isConsentGranted(provider: provider, dataClass: dataClass) {
                allowed.insert(dataClass)
            }
        }
        return allowed
    }
}

/// Applies health-context provenance rules before prompt construction and again
/// to provider-bound continuation messages. Derived recovery is withheld unless
/// all of its source classes are permitted.
enum CloudRequestPolicyGuard {
    static func filtered(_ context: HealthNarrativeContext?, by policy: CloudHealthContextPolicy) -> HealthNarrativeContext? {
        guard let context else { return nil }
        guard !policy.allowedClasses.isEmpty else { return nil }

        let filteredState: HealthStateV2?
        if policy.allows(.healthActivity), let state = context.healthState {
            let domains = state.domains.filter { policy.allows($0.domain) }
            let recovery = policy.allowsDerivedRecovery
                ? state.recovery
                : RecoveryAssessment(
                    status: .insufficientEvidence,
                    confidence: .low,
                    evidence: [],
                    recommendedAction: .collectData
                )
            filteredState = HealthStateV2(
                domains: domains,
                recovery: recovery,
                trainingLoad: state.trainingLoad,
                tomorrowGuidance: policy.allowsDerivedRecovery ? state.tomorrowGuidance : nil
            )
        } else {
            // HealthStateV2 requires a numeric TrainingLoadSummary. Do not serialize
            // placeholder zeros when activity is not authorized; summary fields
            // and individually sourced evidence below still carry allowed classes.
            filteredState = nil
        }

        let evidence = context.evidence.filter { policy.allows(source: $0.source) }
        let recommendations = context.recommendationCandidates.filter { recommendation in
            guard policy.allows(recommendation.domain),
                  policy.allows(evidenceKey: recommendation.evidenceKey) else { return false }
            if recommendation.id.hasPrefix("recovery.") { return policy.allowsDerivedRecovery }
            if recommendation.domain == .nutrition { return policy.allows(.healthActivity) }
            return true
        }
        let subjective = policy.allows(.healthSubjective) ? context.subjectiveContext : nil
        let summary = context.aggregateSummary.map { filtered($0, by: policy) }
        guard filteredState != nil || summary != nil || subjective != nil || !recommendations.isEmpty else {
            return nil
        }
        return HealthNarrativeContext(
            healthState: filteredState,
            evidence: evidence,
            recommendationCandidates: recommendations,
            aggregateSummary: summary,
            subjectiveContext: subjective
        )
    }

    static func filtered(_ summary: HealthContextSummary, by policy: CloudHealthContextPolicy) -> HealthContextSummary {
        func window(_ value: HealthContextWindowSummary) -> HealthContextWindowSummary {
            let coverage = value.coverageDays.filter { key, _ in
                policy.allows(coverageKey: key)
            }
            let dataCoverage = value.dataCoverage.filter { key, _ in
                policy.allows(coverageKey: key)
            }
            return HealthContextWindowSummary(
                windowDays: value.windowDays,
                coverageDays: coverage,
                averageSleepMinutes: policy.allows(.healthSleep) ? value.averageSleepMinutes : nil,
                averageStepCount: policy.allows(.healthActivity) ? value.averageStepCount : nil,
                averageActiveEnergyKcal: policy.allows(.healthActivity) ? value.averageActiveEnergyKcal : nil,
                averageEnergyIntakeKcal: policy.allows(.healthNutrition) ? value.averageEnergyIntakeKcal : nil,
                averageDailyDeficitKcal: policy.allows(.healthNutrition) && policy.allows(.healthActivity)
                    ? value.averageDailyDeficitKcal : nil,
                averageProteinGrams: policy.allows(.healthNutrition) ? value.averageProteinGrams : nil,
                medianWeightKilograms: policy.allows(.healthBody) ? value.medianWeightKilograms : nil,
                dataCoverage: dataCoverage,
                metricWindowCoverage: filterMetricWindowCoverage(value.metricWindowCoverage, by: policy)
            )
        }
        let allowedReferencePrefixes = Set([
            policy.allows(.healthNutrition) ? "nutrition" : nil,
            policy.allows(.healthSleep) ? "sleep" : nil,
            policy.allows(.healthActivity) ? "activity" : nil,
            policy.allows(.healthBody) ? "body" : nil,
        ].compactMap { $0 })
        return HealthContextSummary(
            sevenDay: window(summary.sevenDay),
            twentyEightDay: window(summary.twentyEightDay),
            targetWeightKilograms: policy.allows(.healthBody) ? summary.targetWeightKilograms : nil,
            dailyDeficitGoalKcal: policy.allows(.healthNutrition) && policy.allows(.healthActivity)
                ? summary.dailyDeficitGoalKcal : nil,
            dailyProteinGoalGrams: policy.allows(.healthNutrition) ? summary.dailyProteinGoalGrams : nil,
            recommendationReferences: summary.recommendationReferences.filter { reference in
                allowedReferencePrefixes.contains(String(reference.split(separator: ".").first ?? ""))
            },
            analysisWindowCoverage: filterMetricWindowCoverage(summary.analysisWindowCoverage, by: policy)
        )
    }

    private static func filterMetricWindowCoverage(
        _ coverage: [String: HealthMetricWindowCoverage],
        by policy: CloudHealthContextPolicy
    ) -> [String: HealthMetricWindowCoverage] {
        coverage.filter { policy.allows(coverageKey: $0.key) }
    }

    static func filterConversationHistory(
        _ messages: [ModelMessage],
        currentTurnStartIndex: Int,
        by policy: CloudHealthContextPolicy
    ) -> [ModelMessage] {
        guard messages.indices.contains(currentTurnStartIndex) else { return [] }
        let allHealthClassesAllowed = allHealthClassesAllowed(policy)
        var output: [ModelMessage] = []
        var turn: [ModelMessage] = []
        var isCurrentTurn = false
        func flush() {
            guard !turn.isEmpty else { return }
            let userText = turn.first(where: { $0.role == .user }).flatMap { plainText(in: $0) } ?? ""
            let containsHealthTool = turn.contains { message in
                message.content.contains { content in
                    if case .toolCall(let call) = content { return healthToolNames.contains(call.name) }
                    return false
                }
            }
            let assistantReferencesHealth = turn.contains { message in
                guard message.role == .assistant,
                      let text = plainText(in: message) else { return false }
                return HealthContextPromptBuilder.shouldIncludeSummary(for: text)
            }
            let containsStaleHealthProvenance = turn.contains { message in
                guard let provenance = message.healthContextPolicyProvenance else { return false }
                return provenance.provider != policy.provider
                    || provenance.policyRevision != policy.revision
                    || !provenance.allowedClasses.isSubset(of: policy.allowedClasses)
            }
            // Old user, assistant, or tool messages without a captured policy
            // revision cannot be safely filtered for health text or policy
            // changes. Drop the entire historical turn fail-closed.
            let containsUnprovenancedConversationMessage = turn.contains { message in
                [.user, .assistant, .tool].contains(message.role)
                    && message.healthContextPolicyProvenance == nil
            }
            let containsUnprovenancedHealthTool = turn.contains { message in
                guard message.healthContextPolicyProvenance == nil else { return false }
                return message.content.contains { content in
                    switch content {
                    case .toolCall(let call): isHealthTool(name: call.name)
                    case .toolResult: containsHealthTool
                    case .text, .image, .reasoning: false
                    }
                }
            }
            if isCurrentTurn {
                output.append(contentsOf: allHealthClassesAllowed
                    ? turn
                    : turn.compactMap(restrictCurrentTurnAssistantMessage))
            } else if policy.allowsConversationHistory,
                      !containsStaleHealthProvenance,
                      !containsUnprovenancedConversationMessage,
                      !containsUnprovenancedHealthTool,
                      (allHealthClassesAllowed
                        || (!HealthContextPromptBuilder.shouldIncludeSummary(for: userText)
                            && !containsHealthTool
                            && !assistantReferencesHealth)) {
                output.append(contentsOf: turn)
            }
            turn.removeAll(keepingCapacity: true)
        }
        for (index, message) in messages.enumerated() {
            if message.role == .user && !turn.isEmpty { flush() }
            if index == currentTurnStartIndex { isCurrentTurn = true }
            turn.append(message)
        }
        flush()
        return output
    }

    private static func restrictCurrentTurnAssistantMessage(_ message: ModelMessage) -> ModelMessage? {
        guard message.role == .assistant else { return message }
        // Earlier provider prose or opaque reasoning may repeat health facts from
        // a round whose policy was broader. Only tool-call structure may cross a
        // later, narrower policy boundary; results are filtered separately.
        let toolCalls = message.content.compactMap { content -> ModelContent? in
            if case .toolCall(let call) = content { return .toolCall(call) }
            return nil
        }
        guard !toolCalls.isEmpty else { return nil }
        return ModelMessage(role: .assistant, content: toolCalls)
    }

    static func filterToolResults(in messages: [ModelMessage], by policy: CloudHealthContextPolicy) -> [ModelMessage] {
        var namesByCallID: [String: String] = [:]
        for message in messages {
            for item in message.content {
                if case .toolCall(let call) = item { namesByCallID[call.id] = call.name }
            }
        }
        return messages.map { message in
            let content = message.content.map { item -> ModelContent in
                guard case .toolResult(let callID, let result) = item,
                      let name = namesByCallID[callID],
                      let filtered = filterToolResult(name: name, result: result, by: policy) else { return item }
                return .toolResult(toolCallID: callID, content: filtered)
            }
            return ModelMessage(
                role: message.role,
                content: content,
                inputEnvelope: message.inputEnvelope,
                healthContextPolicyProvenance: message.healthContextPolicyProvenance
            )
        }
    }

    static func isHealthTool(name: String) -> Bool {
        healthToolNames.contains(name)
    }

    private static func filterToolResult(name: String, result: String, by policy: CloudHealthContextPolicy) -> String? {
        switch name {
        case "get_today_health_state":
            return filterTodayHealthState(result, by: policy)
        case "get_health_history":
            return filterHealthHistory(result, by: policy)
        case "get_recent_meals":
            return policy.allows(.healthNutrition) ? nil : restrictedResult
        case "get_metrics", "get_weekly_deficit":
            return policy.allows(.healthNutrition) && policy.allows(.healthActivity) ? nil : restrictedResult
        case "get_recent_workouts", "get_schedule", "get_today_plan":
            return policy.allows(.healthActivity) ? nil : restrictedResult
        case "get_goal":
            return filterGoalResult(result, by: policy)
        default:
            return nil
        }
    }

    private static let restrictedResult = #"{"status":"not_authorized","message":"这些健康数据类别尚未获准用于云端上下文。"}"#
    private static let healthToolNames: Set<String> = [
        "get_today_health_state", "get_health_history", "get_recent_meals", "get_metrics",
        "get_weekly_deficit", "get_recent_workouts", "get_schedule", "get_today_plan", "get_goal",
    ]

    private static func filterTodayHealthState(_ text: String, by policy: CloudHealthContextPolicy) -> String {
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              var root = decoded.objectValue else {
            return restrictedResult
        }
        var safeRoot: [String: JSONValue] = [:]
        safeRoot["asOf"] = root["asOf"]
        if var state = root["healthState"]?.objectValue {
            if case .array(let domains)? = state["domains"] {
                safeRoot["healthState"] = .object([
                    "domains": .array(domains.filter { item in
                    guard let domain = item.objectValue?["domain"]?.stringValue,
                          let dataClass = classForDomain(domain) else { return false }
                    return policy.allows(dataClass)
                    }),
                ])
            } else {
                safeRoot["healthState"] = .object(["domains": .array([])])
            }
            var safeState = safeRoot["healthState"]?.objectValue ?? [:]
            if policy.allowsDerivedRecovery, let recovery = state["recovery"] {
                safeState["recovery"] = recovery
            } else {
                safeState["recovery"] = .object([
                    "status": .string("insufficientEvidence"),
                    "confidence": .string("low"),
                    "evidence": .array([]),
                    "recommendedAction": .string("collectData"),
                ])
            }
            if policy.allows(.healthActivity), let trainingLoad = state["trainingLoad"] {
                safeState["trainingLoad"] = trainingLoad
            }
            safeState["tomorrowGuidance"] = policy.allowsDerivedRecovery
                ? state["tomorrowGuidance"] ?? .null
                : .null
            safeRoot["healthState"] = .object(safeState)
        } else {
            safeRoot["healthState"] = .null
        }
        var safeReferences: [JSONValue] = []
        if case .array(let references)? = root["evidenceReferences"] {
            safeReferences = references.filter { item in
                guard let source = item.objectValue?["source"]?.stringValue else { return false }
                return policy.allows(source: source)
            }
        }
        safeRoot["evidenceReferences"] = .array(safeReferences)
        safeRoot["status"] = .string("policyFiltered")
        safeRoot["message"] = .string(policy.allowedClasses.isEmpty
            ? "没有获准用于云端的健康数据类别。"
            : "只包含已授权的健康数据类别；未展示类别不代表没有记录。")
        return encode(.object(safeRoot)) ?? restrictedResult
    }

    private static func filterGoalResult(_ text: String, by policy: CloudHealthContextPolicy) -> String {
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = decoded.objectValue else {
            return restrictedResult
        }
        let canReadNutritionGoals = policy.allows(.healthNutrition)
        let canReadBodyGoals = policy.allows(.healthBody)
        guard canReadNutritionGoals || canReadBodyGoals else { return restrictedResult }

        let sourceGoal = root["goal"]?.objectValue ?? [:]
        var safeGoal: [String: JSONValue] = [:]
        if canReadBodyGoals, let value = sourceGoal["targetWeightKilograms"], value != .null {
            safeGoal["targetWeightKilograms"] = value
        }
        if canReadNutritionGoals, let value = sourceGoal["dailyProteinGrams"], value != .null {
            safeGoal["dailyProteinGrams"] = value
        }
        if canReadNutritionGoals, policy.allows(.healthActivity),
           let value = sourceGoal["dailyDeficitKcal"], value != .null {
            safeGoal["dailyDeficitKcal"] = value
        }
        if !safeGoal.isEmpty, let effectiveFrom = sourceGoal["effectiveFrom"], effectiveFrom != .null {
            safeGoal["effectiveFrom"] = effectiveFrom
        }

        let hasVisibleGoal = !safeGoal.isEmpty
        var safeRoot: [String: JSONValue] = [:]
        safeRoot["asOf"] = root["asOf"]
        safeRoot["goal"] = hasVisibleGoal ? .object(safeGoal) : .null
        safeRoot["status"] = .string(hasVisibleGoal ? "available" : "unavailable")
        safeRoot["message"] = .string(hasVisibleGoal
            ? "仅包含已授权类别的健康目标。"
            : "获准类别没有可显示的健康目标；未显示类别不代表没有目标。")
        return encode(.object(safeRoot)) ?? restrictedResult
    }

    private static func filterHealthHistory(_ text: String, by policy: CloudHealthContextPolicy) -> String {
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              var root = decoded.objectValue else {
            return restrictedResult
        }
        var filteredDays: [[String: JSONValue]] = []
        if case .array(let days)? = root["days"] {
            for value in days {
                guard case .object(let day) = value else { continue }
                let statuses: [String: JSONValue]
                if case .object(let source)? = day["domainStatuses"] {
                    statuses = source.filter { key, _ in
                        classForDomain(key).map(policy.allows) == true
                    }
                } else {
                    statuses = [:]
                }
                let observations: [String: JSONValue]
                if case .object(let source)? = day["observations"] {
                    observations = source.filter { key, _ in policy.allows(evidenceKey: key) }
                } else {
                    observations = [:]
                }
                var safeDay: [String: JSONValue] = [:]
                safeDay["date"] = day["date"]
                safeDay["domainStatuses"] = .object(statuses)
                safeDay["observations"] = .object(observations)
                if policy.allowsDerivedRecovery, let recovery = day["recoveryStatus"] {
                    safeDay["recoveryStatus"] = recovery
                }
                if policy.allows(.healthActivity), let trainingLoad = day["trainingLoadBand"] {
                    safeDay["trainingLoadBand"] = trainingLoad
                }

                // A date with only forbidden-class fields is itself a side channel.
                // Keep a day only when at least one authorized class contributed a field.
                guard !statuses.isEmpty || !observations.isEmpty
                    || safeDay["recoveryStatus"] != nil || safeDay["trainingLoadBand"] != nil else { continue }
                filteredDays.append(safeDay)
            }
        }
        var safeRoot: [String: JSONValue] = [:]
        safeRoot["startDate"] = root["startDate"]
        safeRoot["endDate"] = root["endDate"]
        safeRoot["days"] = .array(filteredDays.map { .object($0) })

        let hasObservations = filteredDays.contains { day in
            day["observations"]?.objectValue.map { !$0.isEmpty } == true
        }
        let hasUnknownOrPartialCoverage = filteredDays.contains { day in
            day["domainStatuses"]?.objectValue?.values.contains { value in
                value.stringValue == "unknown" || value.stringValue == "partial"
            } == true
        }
        let hasGaps = filteredDays.contains { day in
            let hasDomainGap = day["domainStatuses"]?.objectValue?.values.contains { value in
                value.stringValue == "noData"
                    || value.stringValue == "learning"
                    || value.stringValue == "unknown"
                    || value.stringValue == "partial"
            } == true
            let hasRecoveryGap = day["recoveryStatus"]?.stringValue == "insufficientEvidence"
            return hasDomainGap || hasRecoveryGap
        }
        let status: String
        let message: String
        if policy.allowedClasses.isEmpty {
            status = "notAuthorized"
            message = "没有获准用于云端的健康数据类别。"
        } else if hasUnknownOrPartialCoverage {
            status = "partial"
            message = "已授权类别的覆盖状态未知或不完整；不能据此断言没有记录。"
        } else if !hasObservations {
            status = "noData"
            message = "已授权类别没有可用观测；未授权或未显示类别不代表没有记录。"
        } else if hasGaps {
            status = "partial"
            message = "已授权类别的部分日期或领域证据不足；未授权类别不代表没有记录。"
        } else {
            status = "available"
            message = "仅依据已授权类别的观测汇总。"
        }
        safeRoot["status"] = .string(status)
        safeRoot["message"] = .string(message)
        return encode(.object(safeRoot)) ?? restrictedResult
    }

    private static func encode(_ value: JSONValue) -> String? {
        guard let data = try? value.encodedData() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func plainText(in message: ModelMessage) -> String? {
        message.content.compactMap { item in
            if case .text(let text) = item { return text }
            return nil
        }.joined(separator: "\n")
    }

    private static func allHealthClassesAllowed(_ policy: CloudHealthContextPolicy) -> Bool {
        CloudHealthContextPolicy.dataClasses.allSatisfy { policy.allows($0) }
    }

    private static func classForDomain(_ rawValue: String) -> ProviderDataClass? {
        switch rawValue {
        case "nutrition": .healthNutrition
        case "sleep": .healthSleep
        case "activity": .healthActivity
        case "body": .healthBody
        default: nil
        }
    }

}

private extension CloudHealthContextPolicy {
    func allows(_ domain: HealthDomain) -> Bool {
        switch domain {
        case .nutrition: allows(.healthNutrition)
        case .sleep: allows(.healthSleep)
        case .activity: allows(.healthActivity)
        case .body: allows(.healthBody)
        }
    }

    func allows(source: String) -> Bool {
        let normalized = source.lowercased()
        switch normalized {
        case "subjective", "subjectivehealth", "userreported", "userreporteddailycheckin":
            return allows(.healthSubjective)
        case "sleep", "sleepanalysis":
            return allows(.healthSleep)
        case "activity", "trainingload", "workouts", "steps", "activeenergy", "exercise":
            return allows(.healthActivity)
        case "nutrition", "energyintake", "protein":
            return allows(.healthNutrition)
        case "body", "vitals", "bodyweight", "restingheartrate", "heartratevariability",
             "respiratoryrate", "wristtemperature", "bodymass", "weight":
            return allows(.healthBody)
        default:
            break
        }
        if normalized.hasPrefix("sleep.") { return allows(.healthSleep) }
        if normalized.hasPrefix("activity.") || normalized.hasPrefix("trainingload.") {
            return allows(.healthActivity)
        }
        if normalized.hasPrefix("nutrition.") { return allows(.healthNutrition) }
        if normalized.hasPrefix("body.") || normalized.hasPrefix("vitals.") { return allows(.healthBody) }
        if normalized.hasPrefix("subjective.") || normalized.hasPrefix("userreported.") {
            return allows(.healthSubjective)
        }
        return false
    }

    func allows(evidenceKey: String) -> Bool {
        let normalized = evidenceKey.lowercased()
        if normalized == "trainingload.ratio" { return allows(.healthActivity) }
        return allows(source: normalized)
    }

    func allows(coverageKey: String) -> Bool {
        let normalized = coverageKey.lowercased()
        if normalized.contains("deficit") {
            return allows(.healthNutrition) && allows(.healthActivity)
        }
        if normalized == "proteingrams" { return allows(.healthNutrition) }
        return allows(source: normalized)
    }
}

enum CloudHealthContextPolicyError: Error, Equatable {
    case expansionRequiresConfirmation
    case snapshotRepositoryUnavailable
    case noPendingExpansion
}

enum CloudHealthContextPolicyAlignmentIntent: Equatable {
    case requestExpansion(Set<ProviderDataClass>)
    case revoke(Set<ProviderDataClass>)
    case confirm
    case cancel

    static func parse(_ text: String) -> Self? {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let normalized = text.lowercased().components(separatedBy: separators).joined()
        if ["确认", "我确认", "确认授权", "确认这些类别", "同意这些类别", "是的确认"].contains(normalized) {
            return .confirm
        }
        if ["取消", "我取消", "不同意", "不要", "先不", "算了", "取消授权"].contains(normalized) {
            return .cancel
        }

        let isRevocation = [
            "撤销", "取消授权", "停止使用", "不再使用", "关闭", "不要再",
            "不允许", "不授权", "不同意", "不要上传", "不要使用",
        ].contains { phrase in
            normalized.contains(phrase)
        }
        let classes = mentionedClasses(in: normalized)
        guard !classes.isEmpty else { return nil }
        if isRevocation { return .revoke(classes) }

        let isExplicitExpansion = ["授权", "允许", "同意", "可以用", "可以使用", "希望你用", "希望你使用", "同意你用"].contains { phrase in
            normalized.contains(phrase)
        }
        guard isExplicitExpansion else { return nil }
        return .requestExpansion(classes)
    }

    private static func mentionedClasses(in text: String) -> Set<ProviderDataClass> {
        if ["全部健康", "所有健康", "全部历史健康", "所有历史健康", "健康历史", "历史健康"].contains(where: { text.contains($0) }) {
            return Set(CloudHealthContextPolicy.dataClasses)
        }
        var result = Set<ProviderDataClass>()
        if ["睡眠"].contains(where: { text.contains($0) }) { result.insert(.healthSleep) }
        if ["饮食", "营养", "餐食", "摄入", "蛋白"].contains(where: { text.contains($0) }) { result.insert(.healthNutrition) }
        if ["活动", "训练", "运动", "步数", "消耗"].contains(where: { text.contains($0) }) { result.insert(.healthActivity) }
        if ["体重", "身体测量", "心率", "身体数据"].contains(where: { text.contains($0) }) { result.insert(.healthBody) }
        if ["主观状态", "情绪", "自述", "症状"].contains(where: { text.contains($0) }) { result.insert(.healthSubjective) }
        return result
    }
}
