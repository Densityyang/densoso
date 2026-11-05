import DensosoDomain
import CryptoKit
import Foundation

enum CloudHealthPolicyState: String, Codable, Hashable, Sendable {
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

struct CloudHealthContextPolicyChange: Sendable {
    let provider: ProviderID
    let snapshot: CloudHealthContextPolicySnapshot
    let revokedClasses: Set<ProviderDataClass>

    func affects(requestDataClasses: Set<ProviderDataClass>) -> Bool {
        !revokedClasses.isDisjoint(with: requestDataClasses)
    }
}

struct HealthContentClassification: Equatable, Sendable {
    let dataClasses: Set<ProviderDataClass>
    let hasUnclassifiedHealthContent: Bool
}

/// Classifies factual health content for message provenance and outbound
/// consent checks. This is intentionally independent of health intent
/// detection, which answers whether health context should be retrieved.
enum HealthContentProvenanceClassifier {
    static func classify(_ text: String) -> HealthContentClassification {
        let value = text.lowercased()
        let clauses = healthFactClauses(in: value)
        let dataClasses = clauses.reduce(into: Set<ProviderDataClass>()) { result, clause in
            result.formUnion(recognizedDataClasses(in: clause))
        }
        let hasUnclassifiedHealthContent = clauses.contains { clause in
            guard containsHealthEntity(clause), hasHealthFactCue(clause) else { return false }
            let clauseClasses = recognizedDataClasses(in: clause)
            return clauseClasses.isEmpty || containsAmbiguousMedicalDetail(clause)
        }
        return HealthContentClassification(
            dataClasses: dataClasses,
            hasUnclassifiedHealthContent: hasUnclassifiedHealthContent
        )
    }

    private static func recognizedDataClasses(in value: String) -> Set<ProviderDataClass> {
        var dataClasses = Set<ProviderDataClass>()
        if matches(#"(?i)(?:hrv|rhr)\s*[:：=]?\s*\d"#, in: value)
            || matches(#"(?i)\b(?:resting\s*heart\s*rate|heart\s*rate|blood\s*pressure|weight)\b.{0,16}\d"#, in: value)
            || matches(#"(静息心率|心率|血压|体重|体脂|腰围)\s*(是|[:：=])?\s*\d"#, in: value)
            || matches(#"(?i)(hrv|rhr|heart\s*rate|blood\s*pressure|weight).{0,16}(high|low|normal|elevated|abnormal|poor|good)"#, in: value)
            || matches(#"(心率|血压|体重|体脂|腰围).{0,16}(偏高|偏低|正常|异常)"#, in: value)
            || [
                "diabetes", "diabetic", "asthma", "hypertension", "blood glucose", "glucose",
                "medication", "medicine", "diagnosis", "symptom", "pain", "pregnant", "pregnancy",
                "headache", "dizzy", "nausea", "fever", "cough", "rash", "sore", "illness",
                "糖尿病", "哮喘", "高血压", "低血糖", "血糖", "用药", "药物", "诊断", "症状", "疼痛",
                "头痛", "头疼", "头晕", "恶心", "发烧", "发热", "咳嗽", "皮疹", "不舒服", "不适",
                "过敏", "怀孕", "月经",
            ].contains(where: { value.contains($0) }) {
            dataClasses.insert(.healthBody)
        }

        if matches(#"(睡眠|睡了|睡着|昨晚睡|sleep(?:ing)?|slept).{0,36}(\d|小时|分钟|hour|minute|record|记录|很差|不足|充足|poor|bad|good)"#, in: value)
            || value.contains("睡眠记录") || value.contains("sleep record") {
            dataClasses.insert(.healthSleep)
        }

        if matches(#"\d+\s*步"#, in: value)
            || matches(#"\d+\s*steps?"#, in: value)
            || matches(#"(步数|steps?)\s*[:：=]?\s*\d"#, in: value)
            || matches(#"(走了|walked|ran|跑了|运动了|worked out|workout|exercise|running).{0,18}(\d|公里|千米|km|分钟|minute)"#, in: value) {
            dataClasses.insert(.healthActivity)
        }

        if matches(#"(早餐|午餐|晚餐|加餐|餐食|饮食|摄入|meal|ate|eaten|intake|diet|consumed|consumption).{0,36}(\d|kcal|calorie|千卡|卡路里|吃了|素食|vegetarian)"#, in: value)
            || matches(#"(吃了|摄入).{0,24}(\d|kcal|calorie|千卡|卡路里)"#, in: value)
            || matches(#"(我|今天|刚才|i ).{0,8}(吃了|吃过).{1,48}"#, in: value)
            || matches(#"\b(i ate|ate|eaten|consumed)\b.{1,48}"#, in: value) {
            dataClasses.insert(.healthNutrition)
        }

        if matches(#"(压力|精力|疲劳|疲惫|心情|状态|stress|energy|fatigue|mood).{0,20}(偏高|很大|很累|疲惫|低|高|差|好|\d|high|low|tired|poor|good)"#, in: value)
            || matches(#"(感觉|觉得|feeling|feel).{0,20}(压力|疲劳|疲惫|stress|tired|anxious)"#, in: value) {
            dataClasses.insert(.healthSubjective)
        }
        return dataClasses
    }

    private static func hasHealthFactCue(_ value: String) -> Bool {
        let sensitiveHealthTerms = [
            "diabetes", "diabetic", "asthma", "hypertension", "medication", "medicine",
            "diagnosis", "symptom", "pain", "blood glucose", "glucose", "pregnant", "pregnancy",
            "headache", "dizzy", "nausea", "fever", "cough", "rash", "sore", "illness",
            "糖尿病", "哮喘", "高血压", "低血糖", "血糖", "用药", "药物", "诊断", "症状", "疼痛",
            "头痛", "头疼", "头晕", "恶心", "发烧", "发热", "咳嗽", "皮疹", "不舒服", "不适",
            "过敏", "怀孕", "月经",
        ]
        return sensitiveHealthTerms.contains(where: { value.contains($0) })
            || matches(#"\d"#, in: value)
            || [
                "偏高", "偏低", "很差", "不足", "正常", "异常", "不明", "不清楚", "说不清",
                "不舒服", "不适", "不对劲", "elevated", "high", "low", "normal", "poor", "bad", "unusual",
            ].contains { value.contains($0) }
    }

    private static func containsHealthEntity(_ value: String) -> Bool {
        [
            "hrv", "heart rate", "blood pressure", "recovery", "readiness", "心率", "血压", "体重", "体脂",
            "睡眠", "睡了", "sleep", "步数", "steps", "运动", "训练", "workout", "exercise", "meal",
            "breakfast", "lunch", "dinner", "餐", "饮食", "摄入", "calorie", "kcal", "压力", "精力", "疲劳", "stress",
            "diabetes", "diabetic", "asthma", "hypertension", "medication", "medicine", "diagnosis", "symptom",
            "pain", "blood glucose", "glucose", "pregnant", "pregnancy", "headache", "dizzy", "nausea", "fever", "cough", "rash", "illness",
            "糖尿病", "哮喘", "高血压", "低血糖", "血糖", "用药", "药物", "诊断", "症状", "疼痛", "头痛", "头疼", "头晕",
            "恶心", "发烧", "发热", "咳嗽", "皮疹", "不舒服", "不适", "过敏", "怀孕", "月经",
        ].contains { value.contains($0) }
    }

    private static func containsAmbiguousMedicalDetail(_ value: String) -> Bool {
        ["medication", "medicine", "用药", "药物", "症状", "symptom", "pain", "疼痛", "unknown", "unspecified", "不明", "不清楚", "说不清"]
            .contains(where: { value.contains($0) })
    }

    private static func healthFactClauses(in value: String) -> [String] {
        let clauseConnectors = ["但是", "不过", "而且", "并且", "同时", "另外"]
        let separated = clauseConnectors.reduce(value) { partial, connector in
            partial.replacingOccurrences(of: connector, with: "|")
        }
        let englishConnector = try? NSRegularExpression(pattern: #"(?i)\b(?:and|but|also)\b"#)
        let separatedEnglish = englishConnector?.stringByReplacingMatches(
            in: separated,
            range: NSRange(separated.startIndex..<separated.endIndex, in: separated),
            withTemplate: "|"
        ) ?? separated
        return separatedEnglish
            .components(separatedBy: CharacterSet(charactersIn: "，,。；;!?！？\n|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }
}

private actor CloudHealthContextPolicyChangeHub {
    static let shared = CloudHealthContextPolicyChangeHub()

    private var observers: [UUID: (ProviderID, AsyncStream<CloudHealthContextPolicyChange>.Continuation)] = [:]

    func changes(for provider: ProviderID) -> AsyncStream<CloudHealthContextPolicyChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CloudHealthContextPolicyChange>.makeStream()
        observers[id] = (provider, continuation)
        continuation.onTermination = { @Sendable _ in
            Task { await CloudHealthContextPolicyChangeHub.shared.removeObserver(id) }
        }
        return stream
    }

    func publish(_ change: CloudHealthContextPolicyChange) {
        for (_, (provider, continuation)) in observers where provider == change.provider {
            continuation.yield(change)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

actor CloudHealthPolicySendAttempt {
    struct State: Sendable {
        let serializationGateReleased: Bool
        let networkAttemptAllowed: Bool
        let providerStreamStarted: Bool
        let restrictiveChangeObserved: Bool
    }

    private var serializationGateReleased = false
    private var networkAttemptAllowed = false
    private var providerStreamStarted = false
    private var restrictiveChangeObserved = false
    private var finished = false

    func markSerializationGateReleased() {
        serializationGateReleased = true
    }

    func markNetworkAttemptAllowed() {
        networkAttemptAllowed = true
    }

    func markProviderStreamStarted() {
        providerStreamStarted = true
    }

    func observeRestrictiveChangeWhileActive() -> Bool {
        guard !finished else { return false }
        restrictiveChangeObserved = true
        return true
    }

    func markFinished() {
        finished = true
    }

    func state() -> State {
        State(
            serializationGateReleased: serializationGateReleased,
            networkAttemptAllowed: networkAttemptAllowed,
            providerStreamStarted: providerStreamStarted,
            restrictiveChangeObserved: restrictiveChangeObserved
        )
    }
}

protocol CloudHealthContextPolicySnapshotRepository: Sendable {
    func currentCloudHealthContextPolicySnapshot(provider: ProviderID) async throws -> CloudHealthContextPolicySnapshot
    func currentSendConsentRevisions(provider: ProviderID) async throws -> [ProviderDataClass: String]
    func withCurrentSendAuthorization<Result: Sendable>(
        provider: ProviderID,
        expectedSnapshot: CloudHealthContextPolicySnapshot,
        expectedConsentRevisions: [ProviderDataClass: String],
        requiredClasses: Set<ProviderDataClass>,
        operation: @Sendable () throws -> Result
    ) async throws -> Result
    func stageCloudHealthContextPolicyDraft(
        expectedSnapshot: CloudHealthContextPolicySnapshot,
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        changeSource: CloudHealthPolicyChangeSource
    ) async throws -> CloudHealthContextPolicySnapshot
    func cancelCloudHealthContextPolicyDraft(
        expectedSnapshot: CloudHealthContextPolicySnapshot,
        provider: ProviderID,
        changeSource: CloudHealthPolicyChangeSource
    ) async throws -> CloudHealthContextPolicySnapshot
    func confirmCloudHealthContextPolicyDraft(
        expectedPolicyID: UUID,
        expectedRevision: Int,
        expectedState: CloudHealthPolicyState,
        expectedAllowedClasses: Set<ProviderDataClass>,
        provider: ProviderID,
        confirmedAt: Date,
        changeSource: CloudHealthPolicyChangeSource
    ) async throws -> CloudHealthContextPolicySnapshot
    func updateConversationHistoryConsent(
        expectedSnapshot: CloudHealthContextPolicySnapshot,
        provider: ProviderID,
        allowed: Bool,
        changeSource: CloudHealthPolicyChangeSource,
        confirmedAt: Date?
    ) async throws -> CloudHealthContextPolicySnapshot
    func updateCloudHealthContextPolicy(
        expectedSnapshot: CloudHealthContextPolicySnapshot,
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
    let sendConsentRevisions: [ProviderDataClass: String]

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
        self.sendConsentRevisions = [:]
    }

    private init(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        allowsConversationHistory: Bool,
        snapshot: CloudHealthContextPolicySnapshot,
        sendConsentRevisions: [ProviderDataClass: String]
    ) {
        self.provider = provider
        self.allowedClasses = allowedClasses.intersection(Set(Self.dataClasses))
        self.allowsConversationHistory = allowsConversationHistory
        self.snapshot = snapshot
        self.sendConsentRevisions = sendConsentRevisions
    }

    func allows(_ dataClass: ProviderDataClass) -> Bool {
        allowedClasses.contains(dataClass)
    }

    func consentRevisions(for classes: Set<ProviderDataClass>) -> [ProviderDataClass: String] {
        Dictionary(uniqueKeysWithValues: classes.compactMap { dataClass in
            guard let revision = sendConsentRevisions[dataClass],
                  revision != "<unavailable>", revision != "<unstable>" else { return nil }
            return (dataClass, revision)
        })
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
        let sendConsentRevisions: [ProviderDataClass: String]
        if let policyRepository = repository as? any CloudHealthContextPolicySnapshotRepository {
            let firstRevisions = try await policyRepository.currentSendConsentRevisions(provider: provider)
            let secondRevisions = try await policyRepository.currentSendConsentRevisions(provider: provider)
            sendConsentRevisions = Dictionary(uniqueKeysWithValues: ProviderDataClass.allCases.map { dataClass in
                let first = firstRevisions[dataClass]
                let second = secondRevisions[dataClass]
                return (dataClass, first == second ? (second ?? "<unavailable>") : "<unstable>")
            })
        } else {
            sendConsentRevisions = [:]
        }
        // If consent changes during the asynchronous reads, prefer the class that was denied in either pass.
        let persistedClasses: Set<ProviderDataClass>?
        let readableStates: Set<CloudHealthPolicyState> = [.active, .draft]
        if let firstPolicySnapshot,
           let secondPolicySnapshot,
           readableStates.contains(firstPolicySnapshot.state),
           readableStates.contains(secondPolicySnapshot.state) {
            persistedClasses = firstPolicySnapshot.allowedClasses.intersection(
                secondPolicySnapshot.allowedClasses
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
            snapshotAllowsConversationHistory = readableStates.contains(firstPolicySnapshot.state)
                && readableStates.contains(secondPolicySnapshot.state)
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
            snapshot: snapshot,
            sendConsentRevisions: sendConsentRevisions
        )
    }

    static func applyRestrictiveChange(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        repository: any ProviderGovernanceRepository,
        changeSource: CloudHealthPolicyChangeSource = .agentConversation
    ) async throws -> CloudHealthContextPolicySnapshot {
        let previous = try await load(from: repository, provider: provider)
        let snapshot = try await persist(
            current: previous,
            provider: provider,
            allowedClasses: allowedClasses,
            repository: repository,
            changeSource: changeSource,
            confirmedExpansion: false
        )
        let requestedClasses = allowedClasses.intersection(Set(dataClasses))
        let removedHealthClass = !requestedClasses.isSuperset(of: previous.allowedClasses)
        let removedPersistedClass = !snapshot.allowedClasses.isSuperset(of: previous.snapshot.allowedClasses)
        let revokedPolicy = previous.snapshot.state == .active && snapshot.state != .active
        var revokedClasses = previous.allowedClasses.subtracting(requestedClasses)
            .union(previous.snapshot.allowedClasses.subtracting(snapshot.allowedClasses))
        if revokedPolicy && revokedClasses.isEmpty {
            revokedClasses.formUnion(previous.allowedClasses)
        }
        if removedHealthClass || removedPersistedClass || revokedPolicy {
            await CloudHealthContextPolicyChangeHub.shared.publish(
                CloudHealthContextPolicyChange(
                    provider: provider,
                    snapshot: snapshot,
                    revokedClasses: revokedClasses
                )
            )
        }
        return snapshot
    }

    static func confirmExpandedPolicy(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        repository: any ProviderGovernanceRepository,
        expectedSnapshot: CloudHealthContextPolicySnapshot? = nil,
        confirmedAt: Date = Date(),
        changeSource: CloudHealthPolicyChangeSource = .agentConversation
    ) async throws -> CloudHealthContextPolicySnapshot {
        let current = try await load(from: repository, provider: provider)
        if let expectedSnapshot, current.snapshot != expectedSnapshot {
            throw CloudHealthContextPolicyError.stalePolicyRevision
        }
        return try await persist(
            current: current,
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
        expectedSnapshot: CloudHealthContextPolicySnapshot? = nil,
        confirmedAt: Date? = nil,
        changeSource: CloudHealthPolicyChangeSource = .settings
    ) async throws -> CloudHealthContextPolicySnapshot {
        let current = try await load(from: repository, provider: provider)
        let currentPolicySnapshot = current.snapshot
        if let expectedSnapshot, currentPolicySnapshot != expectedSnapshot {
            throw CloudHealthContextPolicyError.stalePolicyRevision
        }
        let first = try await repository.isConsentGranted(provider: provider, dataClass: .conversationHistory)
        let second = try await repository.isConsentGranted(provider: provider, dataClass: .conversationHistory)
        guard !allowed || (first && second) || confirmedAt != nil else {
            throw CloudHealthContextPolicyError.expansionRequiresConfirmation
        }
        if let snapshotRepository = repository as? any CloudHealthContextPolicySnapshotRepository {
            let snapshot = try await snapshotRepository.updateConversationHistoryConsent(
                expectedSnapshot: currentPolicySnapshot,
                provider: provider,
                allowed: allowed,
                changeSource: changeSource,
                confirmedAt: confirmedAt
            )
            if !allowed && (first || second) {
                await CloudHealthContextPolicyChangeHub.shared.publish(
                    CloudHealthContextPolicyChange(
                        provider: provider,
                        snapshot: snapshot,
                        revokedClasses: [.conversationHistory]
                    )
                )
            }
            return snapshot
        }
        try await repository.setConsent(
            provider: provider,
            dataClass: .conversationHistory,
            granted: allowed,
            policyVersion: "cloud-conversation-history-v1"
        )
        let snapshot = try await currentSnapshotForConsent(from: repository, provider: provider)
        if !allowed && (first || second) {
            await CloudHealthContextPolicyChangeHub.shared.publish(
                CloudHealthContextPolicyChange(
                    provider: provider,
                    snapshot: snapshot,
                    revokedClasses: [.conversationHistory]
                )
            )
        }
        return snapshot
    }

    static func restrictiveChanges(for provider: ProviderID) async -> AsyncStream<CloudHealthContextPolicyChange> {
        await CloudHealthContextPolicyChangeHub.shared.changes(for: provider)
    }

    static func notifyRevokedConsent(
        provider: ProviderID,
        dataClass: ProviderDataClass,
        repository: any ProviderGovernanceRepository
    ) async {
        let snapshot = (try? await load(from: repository, provider: provider).snapshot)
            ?? CloudHealthContextPolicySnapshot.unconfigured(provider: provider)
        await CloudHealthContextPolicyChangeHub.shared.publish(
            CloudHealthContextPolicyChange(
                provider: provider,
                snapshot: snapshot,
                revokedClasses: [dataClass]
            )
        )
    }

    func isMoreRestrictive(than previous: Self) -> Bool {
        guard provider == previous.provider else { return false }
        if !allowedClasses.isSuperset(of: previous.allowedClasses) { return true }
        if previous.allowsConversationHistory && !allowsConversationHistory { return true }
        if previous.snapshot.state == .active && snapshot.state != .active { return true }
        return snapshot != previous.snapshot
            && !snapshot.allowedClasses.isSuperset(of: previous.snapshot.allowedClasses)
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
            expectedSnapshot: current.snapshot,
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
        return try await snapshotRepository.confirmCloudHealthContextPolicyDraft(
            expectedPolicyID: draft.policyID,
            expectedRevision: draft.revision,
            expectedState: .draft,
            expectedAllowedClasses: draft.allowedClasses,
            provider: provider,
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
        return try await snapshotRepository.cancelCloudHealthContextPolicyDraft(
            expectedSnapshot: draft,
            provider: provider,
            changeSource: .agentConversation
        )
    }

    private static func persist(
        current: CloudHealthContextPolicy,
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        repository: any ProviderGovernanceRepository,
        changeSource: CloudHealthPolicyChangeSource,
        confirmedExpansion: Bool,
        confirmedAt: Date? = nil
    ) async throws -> CloudHealthContextPolicySnapshot {
        let allowed = allowedClasses.intersection(Set(dataClasses))
        let additions = allowed.subtracting(current.allowedClasses)
        guard additions.isEmpty || confirmedExpansion else {
            throw CloudHealthContextPolicyError.expansionRequiresConfirmation
        }
        if let snapshotRepository = repository as? any CloudHealthContextPolicySnapshotRepository {
            return try await snapshotRepository.updateCloudHealthContextPolicy(
                expectedSnapshot: current.snapshot,
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
            let requiredClasses = currentSendRequiredClasses(
                expectedHealthPolicy: expectedHealthPolicy,
                includesImage: includesImage,
                requiresHealthText: requiresHealthText,
                additionalRequiredClasses: additionalRequiredClasses
            )
            guard requiredClasses.allSatisfy({ expectedHealthPolicy.sendConsentRevisions[$0] != nil }) else {
                throw ProviderError.consentPolicyChanged(provider: provider)
            }
            return try await snapshotRepository.withCurrentSendAuthorization(
                provider: provider,
                expectedSnapshot: expectedHealthPolicy.snapshot,
                expectedConsentRevisions: expectedHealthPolicy.sendConsentRevisions,
                requiredClasses: requiredClasses,
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
        additionalRequiredClasses: Set<ProviderDataClass> = [],
        operation: @Sendable () throws -> Result
    ) async throws -> Result {
        if let snapshotRepository = repository as? any CloudHealthContextPolicySnapshotRepository {
            guard expectedHealthPolicy.provider == provider,
                  expectedHealthPolicy.snapshot.provider == provider else {
                throw ProviderError.consentPolicyChanged(provider: provider)
            }
            let requiredClasses = currentSendRequiredClasses(
                expectedHealthPolicy: expectedHealthPolicy,
                includesImage: includesImage,
                requiresHealthText: requiresHealthText,
                additionalRequiredClasses: additionalRequiredClasses
            )
            guard requiredClasses.allSatisfy({ expectedHealthPolicy.sendConsentRevisions[$0] != nil }) else {
                throw ProviderError.consentPolicyChanged(provider: provider)
            }
            return try await snapshotRepository.withCurrentSendAuthorization(
                provider: provider,
                expectedSnapshot: expectedHealthPolicy.snapshot,
                expectedConsentRevisions: expectedHealthPolicy.sendConsentRevisions,
                requiredClasses: requiredClasses,
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

    /// Runs an independent cloud request while watching for revocation of any
    /// category the request uses. A matching change cancels the request task;
    /// the final authorization read closes the response/revocation race.
    static func withRevocableSendAttempt<Result: Sendable>(
        from repository: any ProviderGovernanceRepository,
        provider: ProviderID,
        expectedHealthPolicy: Self,
        includesImage: Bool,
        requiresHealthText: Bool = true,
        additionalRequiredClasses: Set<ProviderDataClass> = [],
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let requiredClasses = currentSendRequiredClasses(
            expectedHealthPolicy: expectedHealthPolicy,
            includesImage: includesImage,
            requiresHealthText: requiresHealthText,
            additionalRequiredClasses: additionalRequiredClasses
        )
        let changes = await restrictiveChanges(for: provider)
        return try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                try await validateCurrentSendConsent(
                    from: repository,
                    provider: provider,
                    expectedHealthPolicy: expectedHealthPolicy,
                    includesImage: includesImage,
                    requiresHealthText: requiresHealthText,
                    additionalRequiredClasses: additionalRequiredClasses
                )
                let result = try await operation()
                try Task.checkCancellation()
                try await validateCurrentSendConsent(
                    from: repository,
                    provider: provider,
                    expectedHealthPolicy: expectedHealthPolicy,
                    includesImage: includesImage,
                    requiresHealthText: requiresHealthText,
                    additionalRequiredClasses: additionalRequiredClasses
                )
                return result
            }
            group.addTask {
                for await change in changes {
                    if change.provider == provider,
                       change.affects(requestDataClasses: requiredClasses) {
                        throw ProviderError.consentPolicyChanged(provider: provider)
                    }
                }
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return result
        }
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

        let numericVitalEvidence = Set(context.vitalTrends.compactMap { trend -> String? in
            guard trend.latestMedian != nil else { return nil }
            return trend.evidenceKey
        })
        let numericActivityEvidence = Set(context.activityTrends.compactMap { trend -> String? in
            guard trend.unit == trend.metric.unit,
                  trend.evidenceKey == trend.metric.evidenceKey,
                  let value = trend.currentValue, value.isFinite, value >= 0,
                  trend.dataCoverage != .unknown,
                  trend.status != .unknown, trend.status != .noData else { return nil }
            return trend.metric.evidenceKey
        })
        let filteredActivityTrends = policy.allows(.healthActivity) ? context.activityTrends : []
        let sourceDomains = context.healthState?.domains ?? context.cloudHealthState?.domains ?? []
        let sourceRecovery = context.healthState?.recovery ?? context.cloudHealthState?.recovery
        let sourceTrainingLoad = context.healthState.map { HealthTrainingLoadContext(summary: $0.trainingLoad) }
            ?? context.cloudHealthState?.trainingLoad
        let sourceTomorrowGuidance = context.healthState?.tomorrowGuidance
            ?? context.cloudHealthState?.tomorrowGuidance
        let filteredDomains = sourceDomains.compactMap { domain -> HealthDomainResult? in
            guard policy.allows(domain.domain) else { return nil }
            if domain.domain == .activity {
                let trend = context.activityTrends.first { candidate in
                    domain.evidenceKeys.contains(candidate.metric.evidenceKey)
                        && numericActivityEvidence.contains(candidate.metric.evidenceKey)
                }
                return HealthDomainResult(
                    domain: domain.domain,
                    status: trend?.status ?? .unknown,
                    currentValue: trend?.currentValue,
                    baseline: trend?.baseline ?? HealthBaseline(
                        readiness: .noData,
                        validDays: 0,
                        median: nil,
                        p10: nil,
                        p90: nil,
                        mad: nil
                    ),
                    evidenceKeys: trend.map { [$0.metric.evidenceKey] } ?? [],
                    dataCoverage: trend?.dataCoverage ?? .unknown
                )
            }
            return HealthDomainResult(
                domain: domain.domain,
                status: domain.status,
                currentValue: domain.currentValue,
                baseline: domain.baseline,
                evidenceKeys: domain.evidenceKeys.filter { key in
                    policy.allows(source: domain.domain.rawValue)
                        && policy.allows(evidenceKey: key)
                        && (!key.lowercased().hasPrefix("vitals.") || numericVitalEvidence.contains(key))
                        && !key.lowercased().hasPrefix("activity.")
                }
            )
        }
        let filteredVitals = policy.allows(.healthBody) ? context.vitalTrends : []
        let filteredRecovery = policy.allowsDerivedRecovery
            ? sourceRecovery.map { recovery in
                RecoveryAssessment(
                    status: recovery.status,
                    confidence: recovery.confidence,
                    evidence: filteredEvidence(
                        recovery.evidence,
                        by: policy,
                        numericVitalEvidence: numericVitalEvidence,
                        numericActivityEvidence: numericActivityEvidence
                    ),
                    recommendedAction: recovery.recommendedAction,
                    missingEvidenceKeys: recovery.missingEvidenceKeys?.filter {
                        policy.allows(evidenceKey: $0)
                    }
                )
            }
            : nil
        let filteredGuidance = policy.allowsDerivedRecovery
            ? sourceTomorrowGuidance.map { guidance in
                NextDayGuidance(
                    expectedState: guidance.expectedState,
                    confidence: guidance.confidence,
                    reasons: filteredEvidence(
                        guidance.reasons,
                        by: policy,
                        numericVitalEvidence: numericVitalEvidence,
                        numericActivityEvidence: numericActivityEvidence
                    ),
                    recommendedAction: guidance.recommendedAction,
                    conditionalNote: guidance.conditionalNote
                )
            }
            : nil
        let filteredCloudState: CloudHealthStateContext? = {
            guard !filteredDomains.isEmpty || !filteredVitals.isEmpty
                    || filteredRecovery != nil
                    || (policy.allows(.healthActivity) && sourceTrainingLoad != nil) else {
                return nil
            }
            return CloudHealthStateContext(
                domains: filteredDomains,
                recovery: filteredRecovery,
                trainingLoad: policy.allows(.healthActivity)
                    ? sourceTrainingLoad.map(filteredTrainingLoad)
                    : nil,
                tomorrowGuidance: filteredGuidance
            )
        }()

        let evidence = context.evidence.filter { item in
            guard policy.allows(source: item.source), policy.allows(evidenceKey: item.key) else { return false }
            if isVitalEvidenceSource(item.source) || item.key.lowercased().hasPrefix("vitals.") {
                return numericVitalEvidence.contains(item.key)
            }
            if item.source == HealthDomain.activity.rawValue || item.key.lowercased().hasPrefix("activity.") {
                return item.source == HealthDomain.activity.rawValue
                    && item.key.lowercased().hasPrefix("activity.")
                    && numericActivityEvidence.contains(item.key)
            }
            return true
        }
        let recommendations = context.recommendationCandidates.filter { recommendation in
            guard !recommendation.requiredDataDomains.isEmpty,
                  recommendation.requiredDataDomains.allSatisfy({ policy.allows($0) }),
                  policy.allows(evidenceKey: recommendation.evidenceKey) else { return false }
            if recommendation.evidenceKey.lowercased().hasPrefix("vitals.") {
                guard numericVitalEvidence.contains(recommendation.evidenceKey) else { return false }
            }
            if recommendation.evidenceKey.lowercased().hasPrefix("activity.") {
                guard recommendation.domain == .activity,
                      numericActivityEvidence.contains(recommendation.evidenceKey) else { return false }
            }
            if recommendation.id.hasPrefix("recovery.") { return policy.allowsDerivedRecovery }
            return true
        }
        let subjective = policy.allows(.healthSubjective) ? context.subjectiveContext : nil
        let summary = context.aggregateSummary.map { filtered($0, by: policy) }
        guard filteredCloudState != nil || summary != nil || subjective != nil
                || !filteredActivityTrends.isEmpty || !recommendations.isEmpty else {
            return nil
        }
        return HealthNarrativeContext(
            healthState: nil,
            evidence: evidence,
            recommendationCandidates: recommendations,
            aggregateSummary: summary,
            subjectiveContext: subjective,
            safeVitalTrends: filteredVitals,
            safeActivityTrends: filteredActivityTrends,
            cloudHealthState: filteredCloudState
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
            let containsHealthTool = turn.contains { message in
                message.content.contains { content in
                    if case .toolCall(let call) = content { return healthToolNames.contains(call.name) }
                    return false
                }
            }
            let completedToolCallIDs = Set(turn.flatMap { message in
                message.content.compactMap { content -> String? in
                    if case .toolResult(let callID, _) = content { return callID }
                    return nil
                }
            })
            let containsStaleHealthProvenance = turn.contains { message in
                guard let provenance = message.healthContextPolicyProvenance else { return false }
                guard provenance.provider == policy.provider else { return true }
                var contentClasses = provenance.contentClasses ?? []
                var hasUnclassifiedContent = provenance.hasUnclassifiedHealthContent == true
                if provenance.contentClasses == nil {
                    for content in message.content {
                        guard case .text(let text) = content else { continue }
                        let classification = HealthContentProvenanceClassifier.classify(text)
                        contentClasses.formUnion(classification.dataClasses)
                        hasUnclassifiedContent = hasUnclassifiedContent
                            || classification.hasUnclassifiedHealthContent
                    }
                }
                if !contentClasses.isSubset(of: policy.allowedClasses) {
                    return true
                }
                var generationClasses = contentClasses
                if hasUnclassifiedContent {
                    generationClasses.formUnion(CloudHealthContextPolicy.dataClasses)
                }
                if !generationClasses.isEmpty {
                    if let recordedRevisions = provenance.dataClassConsentRevisions,
                       !recordedRevisions.isEmpty {
                        for dataClass in generationClasses {
                            guard let recorded = recordedRevisions[dataClass],
                                  let current = policy.sendConsentRevisions[dataClass],
                                  recorded == current else { return true }
                        }
                    } else if provenance.policyRevision != policy.revision {
                        // Legacy provenance cannot identify per-category
                        // generations. Fail closed after any policy revision.
                        return true
                    }
                }
                return hasUnclassifiedContent && !allHealthClassesAllowed
            }
            var turnContentClasses = Set<ProviderDataClass>()
            var hasUnclassifiedHealthContent = false
            for message in turn {
                if let provenance = message.healthContextPolicyProvenance {
                    turnContentClasses.formUnion(provenance.contentClasses ?? [])
                    hasUnclassifiedHealthContent = hasUnclassifiedHealthContent
                        || provenance.hasUnclassifiedHealthContent == true
                }
                for content in message.content {
                    guard case .text(let text) = content else { continue }
                    let classification = HealthContentProvenanceClassifier.classify(text)
                    turnContentClasses.formUnion(classification.dataClasses)
                    hasUnclassifiedHealthContent = hasUnclassifiedHealthContent
                        || classification.hasUnclassifiedHealthContent
                    if message.role == .assistant,
                       message.healthContextPolicyProvenance?.contentClasses == nil,
                       HealthContextPromptBuilder.shouldIncludeSummary(for: text),
                       classification.dataClasses.isEmpty {
                        hasUnclassifiedHealthContent = true
                    }
                }
                for content in message.content {
                    guard case .toolCall(let call) = content,
                          isHealthTool(name: call.name),
                          !completedToolCallIDs.contains(call.id) else { continue }
                    hasUnclassifiedHealthContent = true
                }
                if message.role == .tool,
                   message.healthContextPolicyProvenance?.contentClasses == nil,
                   message.content.contains(where: { if case .toolResult = $0 { return true }; return false }) {
                    // Old tool results have no content provenance. The payload
                    // cannot be safely reclassified from display text alone.
                    hasUnclassifiedHealthContent = true
                }
            }
            let containsUnauthorizedHealthContent = !turnContentClasses.isSubset(of: policy.allowedClasses)
                || (hasUnclassifiedHealthContent && !allHealthClassesAllowed)
            // Legacy turns without per-message policy provenance cannot be
            // safely classified and are dropped as a whole.
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
                    : turn.compactMap { restrictCurrentTurnAssistantMessage($0, by: policy) })
            } else if policy.allowsConversationHistory,
                      !containsStaleHealthProvenance,
                      !containsUnprovenancedConversationMessage,
                      !containsUnprovenancedHealthTool,
                      !containsUnauthorizedHealthContent {
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

    private static func restrictCurrentTurnAssistantMessage(
        _ message: ModelMessage,
        by policy: CloudHealthContextPolicy
    ) -> ModelMessage? {
        guard message.role == .assistant else { return message }
        let text = plainText(in: message) ?? ""
        let inferred = HealthContentProvenanceClassifier.classify(text)
        if let provenance = message.healthContextPolicyProvenance,
           provenance.provider == policy.provider {
            let contentClasses = provenance.contentClasses ?? inferred.dataClasses
            let hasUnknownContent = provenance.hasUnclassifiedHealthContent
                ?? (inferred.hasUnclassifiedHealthContent
                    || (contentClasses.isEmpty && HealthContextPromptBuilder.shouldIncludeSummary(for: text)))
            if contentClasses.isSubset(of: policy.allowedClasses),
               (!hasUnknownContent || allHealthClassesAllowed(policy)) {
                // Same-turn content can continue when its actual data classes
                // remain authorized. Tool results are filtered before every send.
                return ModelMessage(
                    role: message.role,
                    content: message.content,
                    healthContextPolicyProvenance: provenance
                )
            }
        }
        // Earlier provider prose or opaque reasoning may repeat health facts from
        // a round whose policy was broader. Only tool-call structure may cross a
        // later, narrower policy boundary; results are filtered separately.
        let toolCalls = message.content.compactMap { content -> ModelContent? in
            if case .toolCall(let call) = content { return .toolCall(call) }
            return nil
        }
        guard !toolCalls.isEmpty else { return nil }
        return ModelMessage(
            role: .assistant,
            content: toolCalls,
            healthContextPolicyProvenance: message.healthContextPolicyProvenance
        )
    }

    static func filterToolResults(in messages: [ModelMessage], by policy: CloudHealthContextPolicy) -> [ModelMessage] {
        var namesByCallID: [String: String] = [:]
        for message in messages {
            for item in message.content {
                if case .toolCall(let call) = item { namesByCallID[call.id] = call.name }
            }
        }
        return messages.compactMap { message -> ModelMessage? in
            var filteredToolDataClasses = Set<ProviderDataClass>()
            var hasUnclassifiedToolContent = false
            let content = message.content.compactMap { item -> ModelContent? in
                guard case .toolResult(let callID, let result) = item else { return item }
                // A tool result without a matching assistant call cannot be
                // attributed to a tool policy. Drop it instead of forwarding
                // potentially sensitive data from a truncated or corrupt turn.
                guard let name = namesByCallID[callID] else { return nil }
                guard let filtered = filterToolResult(
                    name: name,
                    result: result,
                    by: policy,
                    provenance: message.healthContextPolicyProvenance
                ) else {
                    let dataClasses = toolResultDataClasses(name: name, result: result, by: policy)
                    filteredToolDataClasses.formUnion(dataClasses)
                    if isHealthTool(name: name), name != "get_pending_actions", dataClasses.isEmpty {
                        hasUnclassifiedToolContent = true
                    }
                    return item
                }
                let dataClasses = toolResultDataClasses(name: name, result: filtered, by: policy)
                filteredToolDataClasses.formUnion(dataClasses)
                if isHealthTool(name: name),
                   name != "get_pending_actions",
                   filtered != restrictedResult,
                   dataClasses.isEmpty {
                    hasUnclassifiedToolContent = true
                }
                return .toolResult(toolCallID: callID, content: filtered)
            }
            guard message.role != .tool || !content.isEmpty else { return nil }
            let provenance = message.role == .tool
                ? message.healthContextPolicyProvenance.map {
                    var generationClasses = filteredToolDataClasses
                    if hasUnclassifiedToolContent {
                        generationClasses.formUnion(CloudHealthContextPolicy.dataClasses)
                    }
                    return HealthContextPolicyProvenance(
                        provider: $0.provider,
                        policyRevision: $0.policyRevision,
                        allowedClasses: $0.allowedClasses,
                        contentClasses: filteredToolDataClasses,
                        dataClassConsentRevisions: policy.consentRevisions(for: generationClasses),
                        hasUnclassifiedHealthContent: hasUnclassifiedToolContent
                    )
                }
                : message.healthContextPolicyProvenance
            return ModelMessage(
                role: message.role,
                content: content,
                inputEnvelope: message.inputEnvelope,
                healthContextPolicyProvenance: provenance
            )
        }
    }

    private static func toolResultDataClasses(
        name: String,
        result: String,
        by policy: CloudHealthContextPolicy
    ) -> Set<ProviderDataClass> {
        guard result != restrictedResult else { return [] }
        return switch name {
        case "get_today_health_state", "get_health_history":
            policy.allowedClasses
        case "get_recent_meals":
            policy.allows(.healthNutrition) ? [.healthNutrition] : []
        case "get_metrics":
            Set([.healthNutrition, .healthActivity]).intersection(policy.allowedClasses)
        case "get_weekly_deficit":
            policy.allows(.healthNutrition) && policy.allows(.healthActivity)
                ? [.healthNutrition, .healthActivity]
                : []
        case "get_recent_workouts", "get_schedule", "get_today_plan":
            policy.allows(.healthActivity) ? [.healthActivity] : []
        case "get_goal":
            Set([.healthNutrition, .healthBody, .healthActivity]).intersection(policy.allowedClasses)
        case "get_pending_actions":
            PendingActionConsentPolicy.dataClasses(inToolResult: result)
        default:
            []
        }
    }

    static func isHealthTool(name: String) -> Bool {
        healthToolNames.contains(name)
    }

    private static func filterToolResult(
        name: String,
        result: String,
        by policy: CloudHealthContextPolicy,
        provenance: HealthContextPolicyProvenance?
    ) -> String? {
        switch name {
        case "get_today_health_state":
            return filterTodayHealthState(result, by: policy)
        case "get_health_history":
            return filterHealthHistory(result, by: policy)
        case "get_recent_meals":
            return policy.allows(.healthNutrition) ? nil : restrictedResult
        case "get_metrics":
            return filterMetrics(result, by: policy)
        case "get_weekly_deficit":
            return policy.allows(.healthNutrition) && policy.allows(.healthActivity) ? nil : restrictedResult
        case "get_recent_workouts", "get_schedule", "get_today_plan":
            return policy.allows(.healthActivity) ? nil : restrictedResult
        case "get_goal":
            return filterGoalResult(result, by: policy)
        case "get_pending_actions":
            return filterPendingActionsResult(result, by: policy, provenance: provenance)
        default:
            return nil
        }
    }

    private static func filterPendingActionsResult(
        _ text: String,
        by policy: CloudHealthContextPolicy,
        provenance: HealthContextPolicyProvenance?
    ) -> String {
        guard let data = text.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue,
              let actions = root["actions"]?.arrayValue else {
            return restrictedResult
        }
        let oversizedActions = root["oversizedActions"]?.arrayValue ?? []
        let safeActions = actions.compactMap { action in
            PendingActionConsentPolicy.filteredSummary(action, allowedClasses: policy.allowedClasses)
        }
        let safeOversizedActions = oversizedActions.compactMap { action in
            PendingActionConsentPolicy.filteredOversizedReference(
                action,
                allowedClasses: policy.allowedClasses
            )
        }

        // Preserve pagination only for a result produced under this exact
        // policy revision where every action passed the per-item check. A
        // stale or legacy result must not reveal how many newly hidden actions
        // remain beyond its page boundary.
        let paginationIsCurrent = provenance?.provider == policy.provider
            && provenance?.policyRevision == policy.revision
            && provenance?.allowedClasses.isSubset(of: policy.allowedClasses) == true
            && safeActions.count == actions.count
            && safeOversizedActions.count == oversizedActions.count
        let hasMore = paginationIsCurrent && root["hasMore"]?.boolValue == true
        let status: String
        if !safeActions.isEmpty {
            status = "available"
        } else if !safeOversizedActions.isEmpty {
            status = "requiresLocalReview"
        } else {
            status = "noAuthorizedActions"
        }
        let safeRoot: [String: JSONValue] = [
            "status": .string(status),
            "count": .integer(safeActions.count),
            "hasMore": .boolean(hasMore),
            "nextOffset": hasMore ? (root["nextOffset"] ?? .null) : .null,
            "actions": .array(safeActions),
            "oversizedActions": .array(safeOversizedActions),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let safeData = try? encoder.encode(JSONValue.object(safeRoot)) else {
            return restrictedResult
        }
        return String(decoding: safeData, as: UTF8.self)
    }

    private static let restrictedResult = #"{"status":"not_authorized","message":"这些健康数据类别尚未获准用于云端上下文。"}"#
    private static let healthToolNames: Set<String> = [
        "get_today_health_state", "get_health_history", "get_recent_meals", "get_metrics",
        "get_weekly_deficit", "get_recent_workouts", "get_schedule", "get_today_plan", "get_goal",
        "get_pending_actions",
    ]

    private static func filterTodayHealthState(_ text: String, by policy: CloudHealthContextPolicy) -> String {
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = decoded.objectValue else {
            return restrictedResult
        }
        var safeRoot: [String: JSONValue] = [:]
        safeRoot["asOf"] = root["asOf"]
        let activityTrends = policy.allows(.healthActivity)
            ? uniqueActivityTrends(root["activityTrends"]?.arrayValue ?? [], by: policy)
            : []
        let validActivityEvidenceKeys = numericActivityEvidenceKeys(in: activityTrends)
        let vitalTrends = (root["vitalTrends"]?.arrayValue ?? []).compactMap {
            filteredVitalTrend($0, by: policy)
        }
        let validVitalEvidenceKeys = Set(vitalTrends.compactMap { trend in
            trend.objectValue?["evidenceKey"]?.stringValue
        })
        var safeState: [String: JSONValue] = [:]
        if let state = root["healthState"]?.objectValue {
            if case .array(let domains)? = state["domains"] {
                safeState["domains"] = .array(domains.compactMap { item in
                    guard var fields = item.objectValue,
                          let domain = fields["domain"]?.stringValue,
                          let dataClass = classForDomain(domain),
                          policy.allows(dataClass) else { return nil }
                    if domain == HealthDomain.activity.rawValue {
                        let activityKey = fields["evidenceKeys"]?.arrayValue?.compactMap(\.stringValue)
                            .first(where: { validActivityEvidenceKeys.contains($0) })
                        if let activityKey,
                           let activityTrend = activityTrends.first(where: {
                               $0.objectValue?["evidenceKey"]?.stringValue == activityKey
                           })?.objectValue {
                            fields["currentValue"] = activityTrend["currentValue"]
                            fields["baseline"] = activityTrend["baseline"]
                            fields["evidenceKeys"] = .array([.string(activityKey)])
                            if activityTrend["status"]?.stringValue == HealthDomainStatus.partial.rawValue {
                                fields["status"] = .string(HealthDomainStatus.partial.rawValue)
                            }
                        } else {
                            fields["currentValue"] = .null
                            fields["baseline"] = .null
                            fields["evidenceKeys"] = .array([])
                            fields["status"] = .string(HealthDomainStatus.unknown.rawValue)
                        }
                    } else if let keys = fields["evidenceKeys"]?.arrayValue {
                        fields["evidenceKeys"] = .array(keys.filter { key in
                            guard let value = key.stringValue else { return false }
                            return policy.allows(evidenceKey: value)
                                && (!value.lowercased().hasPrefix("vitals.") || validVitalEvidenceKeys.contains(value))
                                && !value.lowercased().hasPrefix("activity.")
                        })
                    }
                    return .object(fields)
                })
            } else {
                safeState["domains"] = .array([])
            }
            if policy.allowsDerivedRecovery, let recovery = state["recovery"] {
                safeState["recovery"] = filteredEvidenceReferences(
                    in: recovery,
                    key: "evidence",
                    by: policy,
                    validVitalEvidenceKeys: validVitalEvidenceKeys,
                    validActivityEvidenceKeys: validActivityEvidenceKeys
                )
            }
            if policy.allows(.healthActivity), let trainingLoad = state["trainingLoad"] {
                safeState["trainingLoad"] = filteredTrainingLoad(trainingLoad)
            }
            if policy.allowsDerivedRecovery, let tomorrowGuidance = state["tomorrowGuidance"] {
                safeState["tomorrowGuidance"] = filteredEvidenceReferences(
                    in: tomorrowGuidance,
                    key: "reasons",
                    by: policy,
                    validVitalEvidenceKeys: validVitalEvidenceKeys,
                    validActivityEvidenceKeys: validActivityEvidenceKeys
                )
            }
        }
        if !vitalTrends.isEmpty { safeRoot["vitalTrends"] = .array(vitalTrends) }
        if !activityTrends.isEmpty { safeRoot["activityTrends"] = .array(activityTrends) }
        let hasVisibleState = !safeState.isEmpty
        safeRoot["healthState"] = hasVisibleState ? .object(safeState) : .null
        var safeReferences: [JSONValue] = []
        if case .array(let references)? = root["evidenceReferences"] {
            safeReferences = references.filter { item in
                guard let source = item.objectValue?["source"]?.stringValue,
                      let key = item.objectValue?["key"]?.stringValue else { return false }
                return policy.allows(source: source)
                    && policy.allows(evidenceKey: key)
                    && (!(isVitalEvidenceSource(source) || key.lowercased().hasPrefix("vitals."))
                        || validVitalEvidenceKeys.contains(key))
                    && (!(source == HealthDomain.activity.rawValue || key.lowercased().hasPrefix("activity."))
                        || (source == HealthDomain.activity.rawValue
                            && key.lowercased().hasPrefix("activity.")
                            && validActivityEvidenceKeys.contains(key)))
            }
        }
        safeRoot["evidenceReferences"] = .array(safeReferences)
        let isPartial = vitalTrends.contains { trend in
            let coverage = trend.objectValue?["dataCoverage"]?.stringValue
            return coverage == HealthDataCoverage.unknown.rawValue || coverage == HealthDataCoverage.partial.rawValue
        } || activityTrends.contains { trend in
            let coverage = trend.objectValue?["dataCoverage"]?.stringValue
            return coverage == HealthDataCoverage.unknown.rawValue || coverage == HealthDataCoverage.partial.rawValue
        } || safeState["trainingLoad"]?.objectValue?["dataCoverage"]?.stringValue.map {
            $0 != HealthDataCoverage.complete.rawValue
        } == true || (safeState["domains"]?.arrayValue ?? []).contains { domain in
            guard let status = domain.objectValue?["status"]?.stringValue else { return true }
            return ["unknown", "partial", "learning"].contains(status)
        }
        let hasAnyVisibleEvidence = vitalTrends.contains { $0.objectValue?["latestMedian"]?.doubleValue != nil }
            || activityTrends.contains { $0.objectValue?["currentValue"]?.doubleValue != nil }
            || (safeState["domains"]?.arrayValue ?? []).contains {
                $0.objectValue?["currentValue"]?.doubleValue != nil
            }
            || safeState["trainingLoad"]?.objectValue?["ratio"]?.doubleValue != nil
        let status: String
        if policy.allowedClasses.isEmpty {
            status = "notAuthorized"
        } else if hasAnyVisibleEvidence, !isPartial {
            status = "available"
        } else if hasAnyVisibleEvidence || isPartial {
            status = "partial"
        } else {
            status = "noData"
        }
        safeRoot["status"] = .string(status)
        safeRoot["message"] = .string(status == "available"
            ? "仅包含已授权类别的健康数据；未展示类别不代表没有记录。"
            : "已授权类别当前数据不足或覆盖不完整；数据空缺不代表零。")
        return encode(.object(safeRoot)) ?? restrictedResult
    }

    private static func filteredEvidence(
        _ references: [EvidenceReference],
        by policy: CloudHealthContextPolicy,
        numericVitalEvidence: Set<String>,
        numericActivityEvidence: Set<String>
    ) -> [EvidenceReference] {
        references.filter { reference in
            guard policy.allows(source: reference.source), policy.allows(evidenceKey: reference.key) else { return false }
            if isVitalEvidenceSource(reference.source) || reference.key.lowercased().hasPrefix("vitals.") {
                return numericVitalEvidence.contains(reference.key)
            }
            if reference.source == HealthDomain.activity.rawValue
                || reference.key.lowercased().hasPrefix("activity.") {
                return reference.source == HealthDomain.activity.rawValue
                    && reference.key.lowercased().hasPrefix("activity.")
                    && numericActivityEvidence.contains(reference.key)
            }
            return true
        }
    }

    private static func filteredTrainingLoad(_ value: JSONValue) -> JSONValue {
        guard var load = value.objectValue else { return value }
        let coverage = load["dataCoverage"]?.stringValue
            .flatMap { HealthDataCoverage(rawValue: $0)?.rawValue }
            ?? HealthDataCoverage.unknown.rawValue
        load["dataCoverage"] = .string(coverage)
        let readiness = load["readiness"]?.stringValue
        let band = load["band"]?.stringValue
        let hasMeasuredLoad = coverage == HealthDataCoverage.complete.rawValue
            && readiness != BaselineReadiness.noData.rawValue
            && band != TrainingLoadBand.unavailable.rawValue
        guard hasMeasuredLoad else {
            for key in [
                "recentSevenDayLoad", "priorTwentyEightDayAverage", "ratio", "band",
                "estimatedWorkoutCount", "unavailableEffortCount",
            ] {
                if key == "band", coverage == HealthDataCoverage.complete.rawValue,
                   band == TrainingLoadBand.unavailable.rawValue {
                    continue
                }
                load.removeValue(forKey: key)
            }
            return .object(load)
        }
        return .object(load)
    }

    private static func filteredTrainingLoad(_ value: HealthTrainingLoadContext) -> HealthTrainingLoadContext {
        HealthTrainingLoadContext(
            recentSevenDayLoad: value.recentSevenDayLoad,
            priorTwentyEightDayAverage: value.priorTwentyEightDayAverage,
            ratio: value.ratio,
            readiness: value.readiness,
            band: value.band,
            dataCoverage: value.dataCoverage,
            estimatedWorkoutCount: value.estimatedWorkoutCount,
            unavailableEffortCount: value.unavailableEffortCount
        )
    }

    private static func filteredEvidenceReferences(
        in value: JSONValue,
        key: String,
        by policy: CloudHealthContextPolicy,
        validVitalEvidenceKeys: Set<String>,
        validActivityEvidenceKeys: Set<String>
    ) -> JSONValue {
        guard var object = value.objectValue,
              let references = object[key]?.arrayValue else { return value }
        object[key] = .array(references.filter { reference in
            guard let source = reference.objectValue?["source"]?.stringValue,
                  let evidenceKey = reference.objectValue?["key"]?.stringValue else { return false }
            return policy.allows(source: source)
                && policy.allows(evidenceKey: evidenceKey)
                && (!(isVitalEvidenceSource(source) || evidenceKey.lowercased().hasPrefix("vitals."))
                    || validVitalEvidenceKeys.contains(evidenceKey))
                && (!(source == HealthDomain.activity.rawValue || evidenceKey.lowercased().hasPrefix("activity."))
                    || (source == HealthDomain.activity.rawValue
                        && evidenceKey.lowercased().hasPrefix("activity.")
                        && validActivityEvidenceKeys.contains(evidenceKey)))
        })
        return .object(object)
    }

    private static func filteredVitalTrend(_ value: JSONValue, by policy: CloudHealthContextPolicy) -> JSONValue? {
        guard policy.allows(.healthBody),
              let trend = value.objectValue,
              let metricRaw = trend["metric"]?.stringValue,
              let metric = HealthVitalMetric(rawValue: metricRaw) else { return nil }
        let decodedCoverage = trend["dataCoverage"]?.stringValue.flatMap { HealthDataCoverage(rawValue: $0) } ?? .unknown
        let sourceStatus = trend["status"]?.stringValue.flatMap { HealthDomainStatus(rawValue: $0) } ?? .unknown
        let coverage: HealthDataCoverage
        if decodedCoverage == .unknown || sourceStatus == .unknown {
            coverage = .unknown
        } else if decodedCoverage == .partial || sourceStatus == .partial {
            coverage = .partial
        } else {
            coverage = .complete
        }
        let measurement = trend["latestMedian"]?.doubleValue
        let hasMeasurement = measurement?.isFinite == true
        let expectedEvidenceKey = "vitals.\(metric.rawValue).median"
        let hasAuthorizedEvidence = trend["evidenceKey"]?.stringValue == expectedEvidenceKey
            && policy.allows(evidenceKey: expectedEvidenceKey)
        let canUseMeasurement = coverage != .unknown
            && sourceStatus != .unknown && sourceStatus != .noData
            && hasMeasurement && hasAuthorizedEvidence

        var safe: [String: JSONValue] = [
            "metric": .string(metric.rawValue),
            "unit": .string(unit(for: metric)),
            "sourceProvenance": .string(provenance(for: metric).rawValue),
            "dataCoverage": .string(coverage.rawValue),
            "currentWindowDays": .integer(1),
            "baselineWindowDays": .integer(max(HealthDataWindowContract.analysisLookbackDays - 1, 0)),
            "status": .string(coverage == .unknown
                ? HealthDomainStatus.unknown.rawValue
                : (coverage == .partial
                    ? HealthDomainStatus.partial.rawValue
                    : sourceStatus.rawValue)),
        ]
        if coverage != .unknown,
           let baseline = trend["baseline"]?.objectValue {
            let allowedBaselineFields: Set<String> = ["readiness", "validDays", "median", "p10", "p90", "mad"]
            safe["baseline"] = .object(baseline.filter { allowedBaselineFields.contains($0.key) })
        }
        if canUseMeasurement, let measurement {
            safe["latestMedian"] = .number(measurement)
            if let count = trend["currentSampleCount"]?.intValue, count > 0 {
                safe["currentSampleCount"] = .integer(count)
            }
            if let baseline = trend["baseline"]?.objectValue,
               let median = baseline["median"]?.doubleValue,
               let mad = baseline["mad"]?.doubleValue,
               mad.isFinite, mad > 1e-9 {
                let robustZ = 0.6745 * (measurement - median) / mad
                if robustZ.isFinite { safe["robustZScore"] = .number(robustZ) }
            }
            safe["evidenceKey"] = .string(expectedEvidenceKey)
        } else if coverage == .complete {
            safe["status"] = .string(HealthDomainStatus.noData.rawValue)
        }
        return .object(safe)
    }

    private static func uniqueActivityTrends(_ values: [JSONValue], by policy: CloudHealthContextPolicy) -> [JSONValue] {
        var seen = Set<HealthActivityMetric>()
        return Array(values.compactMap { filteredActivityTrend($0, by: policy) }.filter { value in
            guard let rawMetric = value.objectValue?["metric"]?.stringValue,
                  let metric = HealthActivityMetric(rawValue: rawMetric) else { return false }
            return seen.insert(metric).inserted
        }.prefix(HealthActivityMetric.allCases.count))
    }

    private static func numericActivityEvidenceKeys(in trends: [JSONValue]) -> Set<String> {
        Set(trends.compactMap { value -> String? in
            guard let trend = value.objectValue,
                  let rawMetric = trend["metric"]?.stringValue,
                  let metric = HealthActivityMetric(rawValue: rawMetric),
                  trend["unit"]?.stringValue == metric.unit,
                  trend["evidenceKey"]?.stringValue == metric.evidenceKey,
                  let currentValue = trend["currentValue"]?.doubleValue,
                  currentValue.isFinite, currentValue >= 0,
                  trend["dataCoverage"]?.stringValue != HealthDataCoverage.unknown.rawValue,
                  trend["status"]?.stringValue != HealthDomainStatus.unknown.rawValue,
                  trend["status"]?.stringValue != HealthDomainStatus.noData.rawValue else { return nil }
            return metric.evidenceKey
        })
    }

    private static func filteredActivityTrend(_ value: JSONValue, by policy: CloudHealthContextPolicy) -> JSONValue? {
        guard policy.allows(.healthActivity),
              let trend = value.objectValue,
              let metricRaw = trend["metric"]?.stringValue,
              let metric = HealthActivityMetric(rawValue: metricRaw),
              trend["unit"]?.stringValue == metric.unit,
              let baselineWindowDays = trend["baselineWindowDays"]?.intValue,
              (0...28).contains(baselineWindowDays) else { return nil }

        let suppliedEvidenceKey = trend["evidenceKey"]?.stringValue
        if let suppliedEvidenceKey, suppliedEvidenceKey != metric.evidenceKey { return nil }

        let decodedCoverage = trend["dataCoverage"]?.stringValue
            .flatMap { HealthDataCoverage(rawValue: $0) } ?? .unknown
        let sourceStatus = trend["status"]?.stringValue
            .flatMap { HealthDomainStatus(rawValue: $0) } ?? .unknown
        let coverage: HealthDataCoverage
        if decodedCoverage == .unknown || sourceStatus == .unknown {
            coverage = .unknown
        } else if decodedCoverage == .partial || sourceStatus == .partial {
            coverage = .partial
        } else {
            coverage = .complete
        }
        let rawValue: Double?
        if let encodedValue = trend["currentValue"], encodedValue != .null {
            guard let parsedValue = encodedValue.doubleValue,
                  parsedValue.isFinite,
                  parsedValue >= 0 else { return nil }
            rawValue = parsedValue
        } else {
            rawValue = nil
        }
        if rawValue != nil, suppliedEvidenceKey != metric.evidenceKey { return nil }
        let canUseValue = coverage != .unknown
            && sourceStatus != .unknown && sourceStatus != .noData
            && suppliedEvidenceKey == metric.evidenceKey
            && rawValue != nil

        var safe: [String: JSONValue] = [
            "metric": .string(metric.rawValue),
            "unit": .string(metric.unit),
            "baselineWindowDays": .integer(baselineWindowDays),
            "status": .string(coverage == .unknown
                ? HealthDomainStatus.unknown.rawValue
                : (coverage == .partial
                    ? HealthDomainStatus.partial.rawValue
                    : (canUseValue ? sourceStatus.rawValue : HealthDomainStatus.noData.rawValue))),
            "dataCoverage": .string(coverage.rawValue),
        ]
        if coverage != .unknown, let baseline = trend["baseline"]?.objectValue {
            var safeBaseline: [String: JSONValue] = [:]
            if let readiness = baseline["readiness"]?.stringValue,
               BaselineReadiness(rawValue: readiness) != nil {
                safeBaseline["readiness"] = .string(readiness)
            }
            if let validDays = baseline["validDays"]?.intValue, (0...28).contains(validDays) {
                safeBaseline["validDays"] = .integer(validDays)
            }
            for key in ["median", "p10", "p90", "mad"] {
                if let number = baseline[key]?.doubleValue, number.isFinite, number >= 0 {
                    safeBaseline[key] = .number(number)
                }
            }
            if !safeBaseline.isEmpty { safe["baseline"] = .object(safeBaseline) }
        }
        if canUseValue, let rawValue {
            safe["currentValue"] = .number(rawValue)
            safe["evidenceKey"] = .string(metric.evidenceKey)
        }
        return .object(safe)
    }

    private static func unit(for metric: HealthVitalMetric) -> String {
        switch metric {
        case .restingHeartRate: "bpm"
        case .heartRateVariability: "ms"
        case .respiratoryRate: "breaths/min"
        case .wristTemperature: "°C"
        case .bodyWeight: "kg"
        }
    }

    private static func provenance(for metric: HealthVitalMetric) -> HealthVitalAggregateProvenance {
        switch metric {
        case .restingHeartRate, .heartRateVariability, .respiratoryRate, .wristTemperature:
            .healthKitAggregate
        case .bodyWeight:
            .localOrHealthKitAggregate
        }
    }

    private static func filterMetrics(_ text: String, by policy: CloudHealthContextPolicy) -> String? {
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = decoded.objectValue else { return restrictedResult }
        let allowsNutrition = policy.allows(.healthNutrition)
        let allowsActivity = policy.allows(.healthActivity)
        guard allowsNutrition || allowsActivity else { return restrictedResult }
        let allowsCrossDomain = allowsNutrition && allowsActivity

        var safeRoot: [String: JSONValue] = [:]
        for key in ["startDate", "endDate", "timeZone", "requestedDays", "truncated", "nextStartDate"] {
            if let value = root[key] { safeRoot[key] = value }
        }
        for key in ["intake", "proteinG", "fatG", "carbsG"] where allowsNutrition {
            if let value = root[key] { safeRoot[key] = filteredMetricValue(value) }
        }
        if allowsActivity, let expenditure = root["expenditure"] {
            safeRoot["expenditure"] = filteredMetricValue(expenditure)
        }
        if allowsCrossDomain {
            for key in ["deficit", "averageDailyDeficit", "projectedWeightLossKg", "projectedWeightLossNote"] {
                if let value = root[key] { safeRoot[key] = filteredMetricValue(value) }
            }
        }
        if allowsNutrition, let quality = root["energyQuality"] { safeRoot["energyQuality"] = quality }
        if let breakdown = root["dailyBreakdown"]?.arrayValue {
            safeRoot["dailyBreakdown"] = .array(breakdown.compactMap { filterDailyMetricsBreakdown($0, policy: policy) })
        }

        let primaryCoverageKey = allowsCrossDomain ? "deficit" : (allowsNutrition ? "intake" : "expenditure")
        let coverage = root[primaryCoverageKey]?.objectValue?["coverage"]?.objectValue ?? [:]
        let requestedDays = root["requestedDays"]?.intValue ?? coverage["expectedDays"]?.intValue ?? 0
        let availableDays = coverage["availableDays"]?.intValue ?? 0
        let missingDays = max(requestedDays - availableDays, 0)
        if allowsNutrition {
            for key in [
                "daysWithRecordedMeals", "daysWithValidIntakeEstimate",
                "daysWithValidProteinEstimate", "completeRecordDays",
            ] {
                if let value = root[key] { safeRoot[key] = value }
            }
        }
        // These legacy fields are produced from deficit coverage, which depends
        // on both intake and expenditure. Do not reinterpret them as nutrition
        // coverage when only one domain is authorized.
        if allowsCrossDomain {
            safeRoot["validEnergyDays"] = .integer(availableDays)
            safeRoot["missingEnergyDays"] = .integer(missingDays)
        }
        let hasIncompleteCoverage = missingDays > 0
            || (coverage["partialDays"]?.intValue ?? 0) > 0
            || (coverage["unavailableDays"]?.intValue ?? 0) > 0
            || (coverage["pendingRecomputeDays"]?.intValue ?? 0) > 0
        safeRoot["status"] = .string(availableDays == 0
            ? "insufficient_data"
            : (hasIncompleteCoverage ? "partial" : "available"))
        return encode(.object(safeRoot)) ?? restrictedResult
    }

    private static func filteredMetricValue(_ value: JSONValue) -> JSONValue {
        guard let object = value.objectValue else { return value }
        var filtered: [String: JSONValue] = [:]
        for key in ["total", "average"] {
            if let item = object[key] { filtered[key] = filteredMetricValue(item) }
        }
        for key in ["value", "availability", "sourceReferences", "sourceReferencesTruncated", "coverage"] {
            if let item = object[key] { filtered[key] = item }
        }
        return .object(filtered)
    }

    private static func filterDailyMetricsBreakdown(
        _ value: JSONValue,
        policy: CloudHealthContextPolicy
    ) -> JSONValue? {
        guard let day = value.objectValue else { return nil }
        let allowsNutrition = policy.allows(.healthNutrition)
        let allowsActivity = policy.allows(.healthActivity)
        let allowsCrossDomain = allowsNutrition && allowsActivity
        var safeDay: [String: JSONValue] = [:]
        if let date = day["date"] { safeDay["date"] = date }
        for key in ["intake", "proteinG", "fatG", "carbsG"] where allowsNutrition {
            if let value = day[key] { safeDay[key] = value }
        }
        if allowsActivity, let expenditure = day["expenditure"] { safeDay["expenditure"] = expenditure }
        if allowsCrossDomain, let deficit = day["deficit"] { safeDay["deficit"] = deficit }
        if allowsNutrition, let energyQuality = day["energyQuality"] { safeDay["energyQuality"] = energyQuality }
        if allowsNutrition {
            for key in ["nutritionRecordStatus", "lastMealRecordedAt"] {
                if let value = day[key] { safeDay[key] = value }
            }
        }
        if let coverage = day["coverage"]?.objectValue {
            let allowedKeys = Set([
                allowsNutrition ? "intake" : nil,
                allowsActivity ? "expenditure" : nil,
                allowsCrossDomain ? "deficit" : nil,
                allowsNutrition ? "proteinG" : nil,
                allowsNutrition ? "fatG" : nil,
                allowsNutrition ? "carbsG" : nil,
            ].compactMap { $0 })
            safeDay["coverage"] = .object(coverage.filter { allowedKeys.contains($0.key) })
        }
        guard safeDay.keys.contains(where: { $0 != "date" }) else { return nil }
        return .object(safeDay)
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
                let vitalTrends = policy.allows(.healthBody)
                    ? (day["vitalTrends"]?.arrayValue ?? []).compactMap { trend in
                        filteredVitalTrend(trend, by: policy)
                    }
                    : []
                let validVitalEvidenceKeys = Set(vitalTrends.compactMap { trend in
                    trend.objectValue?["evidenceKey"]?.stringValue
                })
                let activityTrends = policy.allows(.healthActivity)
                    ? uniqueActivityTrends(day["activityTrends"]?.arrayValue ?? [], by: policy)
                    : []
                let validActivityEvidenceKeys = numericActivityEvidenceKeys(in: activityTrends)
                let observations: [String: JSONValue]
                if case .object(let source)? = day["observations"] {
                    observations = source.filter { key, _ in
                        guard policy.allows(evidenceKey: key) else { return false }
                        if key.lowercased().hasPrefix("vitals.") {
                            return validVitalEvidenceKeys.contains(key)
                        }
                        if key.lowercased().hasPrefix("activity.") {
                            return validActivityEvidenceKeys.contains(key)
                        }
                        return true
                    }
                } else {
                    observations = [:]
                }
                var safeDay: [String: JSONValue] = [:]
                safeDay["date"] = day["date"]
                safeDay["domainStatuses"] = .object(statuses)
                safeDay["observations"] = .object(observations)
                if !vitalTrends.isEmpty { safeDay["vitalTrends"] = .array(vitalTrends) }
                if !activityTrends.isEmpty { safeDay["activityTrends"] = .array(activityTrends) }
                if policy.allowsDerivedRecovery, let recovery = day["recoveryStatus"] {
                    safeDay["recoveryStatus"] = recovery
                }
                let sourceTrainingLoadCoverage = day["trainingLoadCoverage"]?.stringValue
                    ?? ((day["trainingLoadBand"] != nil || statuses[HealthDomain.activity.rawValue] != nil)
                        ? HealthDataCoverage.unknown.rawValue
                        : nil)
                let trainingLoadCoverage = sourceTrainingLoadCoverage.map {
                    HealthDataCoverage(rawValue: $0)?.rawValue ?? HealthDataCoverage.unknown.rawValue
                }
                if policy.allows(.healthActivity), let trainingLoadCoverage {
                    safeDay["trainingLoadCoverage"] = .string(trainingLoadCoverage)
                    if trainingLoadCoverage == HealthDataCoverage.complete.rawValue,
                       let trainingLoad = day["trainingLoadBand"] {
                        safeDay["trainingLoadBand"] = trainingLoad
                    }
                }

                // A date with only forbidden-class fields is itself a side channel.
                // Keep a day only when at least one authorized class contributed a field.
                guard !statuses.isEmpty || !observations.isEmpty
                    || safeDay["recoveryStatus"] != nil || safeDay["trainingLoadCoverage"] != nil
                    || safeDay["vitalTrends"] != nil || safeDay["activityTrends"] != nil else { continue }
                filteredDays.append(safeDay)
            }
        }
        var safeRoot: [String: JSONValue] = [:]
        safeRoot["startDate"] = root["startDate"]
        safeRoot["endDate"] = root["endDate"]
        safeRoot["days"] = .array(filteredDays.map { .object($0) })

        let hasObservations = filteredDays.contains { day in
            day["observations"]?.objectValue.map { !$0.isEmpty } == true
                || (day["activityTrends"]?.arrayValue ?? []).contains {
                    $0.objectValue?["currentValue"]?.doubleValue?.isFinite == true
                }
        }
        let hasUnknownOrPartialCoverage = filteredDays.contains { day in
            let hasDomainCoverageGap = day["domainStatuses"]?.objectValue?.values.contains { value in
                value.stringValue == "unknown" || value.stringValue == "partial"
            } == true
            let trainingLoadCoverage = day["trainingLoadCoverage"]?.stringValue
            let hasTrainingLoadCoverageGap = policy.allows(.healthActivity)
                && (trainingLoadCoverage == HealthDataCoverage.unknown.rawValue
                    || trainingLoadCoverage == HealthDataCoverage.partial.rawValue)
            let hasVitalCoverageGap = (day["vitalTrends"]?.arrayValue ?? []).contains { trend in
                let coverage = trend.objectValue?["dataCoverage"]?.stringValue
                return coverage == HealthDataCoverage.unknown.rawValue
                    || coverage == HealthDataCoverage.partial.rawValue
            }
            let hasActivityCoverageGap = (day["activityTrends"]?.arrayValue ?? []).contains { trend in
                let coverage = trend.objectValue?["dataCoverage"]?.stringValue
                return coverage == HealthDataCoverage.unknown.rawValue
                    || coverage == HealthDataCoverage.partial.rawValue
            }
            return hasDomainCoverageGap || hasTrainingLoadCoverageGap || hasVitalCoverageGap || hasActivityCoverageGap
        }
        let hasGaps = filteredDays.contains { day in
            let hasDomainGap = day["domainStatuses"]?.objectValue?.values.contains { value in
                value.stringValue == "noData"
                    || value.stringValue == "learning"
                    || value.stringValue == "unknown"
                    || value.stringValue == "partial"
            } == true
            let hasRecoveryGap = day["recoveryStatus"]?.stringValue == "insufficientEvidence"
            let hasTrainingLoadGap = policy.allows(.healthActivity)
                && day["trainingLoadCoverage"]?.stringValue != HealthDataCoverage.complete.rawValue
            let hasVitalGap = (day["vitalTrends"]?.arrayValue ?? []).contains { trend in
                let coverage = trend.objectValue?["dataCoverage"]?.stringValue
                let status = trend.objectValue?["status"]?.stringValue
                return coverage != HealthDataCoverage.complete.rawValue
                    || status == HealthDomainStatus.unknown.rawValue
                    || status == HealthDomainStatus.partial.rawValue
                    || status == HealthDomainStatus.noData.rawValue
            }
            let hasActivityGap = (day["activityTrends"]?.arrayValue ?? []).contains { trend in
                let coverage = trend.objectValue?["dataCoverage"]?.stringValue
                let status = trend.objectValue?["status"]?.stringValue
                return coverage != HealthDataCoverage.complete.rawValue
                    || status == HealthDomainStatus.unknown.rawValue
                    || status == HealthDomainStatus.partial.rawValue
                    || status == HealthDomainStatus.noData.rawValue
                    || status == HealthDomainStatus.learning.rawValue
            }
            return hasDomainGap || hasRecoveryGap || hasTrainingLoadGap || hasVitalGap || hasActivityGap
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

    private static func isVitalEvidenceSource(_ source: String) -> Bool {
        HealthVitalMetric(rawValue: source) != nil
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
    case stalePolicyRevision
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
