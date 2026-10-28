import DensosoDomain
import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class CloudHealthContextPolicyTests: XCTestCase {
    func testConsentRevocationOnlyAffectsRequestsUsingThatDataClass() {
        let snapshot = CloudHealthContextPolicySnapshot.unconfigured(provider: .qwen)
        let request = ModelMessage(role: .user, text: "随便聊聊")
        let policy = CloudHealthContextPolicy(provider: .qwen, allowedClasses: [.healthSleep, .healthActivity])
        let textDependencies = AgentSession.outboundConsentDependencies(
            messages: [request],
            includesImage: false,
            includesConversationHistory: false,
            summary: nil,
            structuredContext: nil,
            policy: policy
        )
        let imageDependencies = AgentSession.outboundConsentDependencies(
            messages: [request],
            includesImage: true,
            includesConversationHistory: false,
            summary: nil,
            structuredContext: nil,
            policy: policy
        )
        let sleepContext = HealthNarrativeContext(
            healthState: nil,
            evidence: [EvidenceReference(key: "sleep.mainSleep.minutes", source: "sleep")],
            recommendationCandidates: [],
            aggregateSummary: nil
        )
        let sleepDependencies = AgentSession.outboundConsentDependencies(
            messages: [request],
            includesImage: false,
            includesConversationHistory: false,
            summary: nil,
            structuredContext: sleepContext,
            policy: policy
        )
        let historyDependencies = AgentSession.outboundConsentDependencies(
            messages: [request],
            includesImage: false,
            includesConversationHistory: true,
            summary: nil,
            structuredContext: nil,
            policy: policy
        )
        let goalCall = ToolCall(
            id: "goal-dependency",
            name: "get_goal",
            arguments: .object([:])
        )
        let goalPolicy = CloudHealthContextPolicy(
            provider: .qwen,
            allowedClasses: [.healthNutrition, .healthBody, .healthActivity]
        )
        let goalDependencies = AgentSession.outboundConsentDependencies(
            messages: [
                ModelMessage(role: .assistant, content: [.toolCall(goalCall)]),
                ModelMessage(
                    role: .tool,
                    content: [.toolResult(toolCallID: goalCall.id, content: #"{"goal":{"dailyDeficitKcal":500}}"#)]
                ),
            ],
            includesImage: false,
            includesConversationHistory: false,
            summary: nil,
            structuredContext: nil,
            policy: goalPolicy
        )

        XCTAssertEqual(textDependencies, [.healthText])
        XCTAssertTrue(imageDependencies.contains(.mealImage))
        XCTAssertFalse(textDependencies.contains(.mealImage))
        XCTAssertFalse(textDependencies.contains(.speechAudio))
        XCTAssertTrue(sleepDependencies.contains(.healthSleep))
        XCTAssertFalse(sleepDependencies.contains(.healthActivity))
        XCTAssertTrue(historyDependencies.contains(.conversationHistory))
        XCTAssertTrue(goalDependencies.contains(.healthActivity))

        let imageRevocation = CloudHealthContextPolicyChange(
            provider: .qwen,
            snapshot: snapshot,
            revokedClasses: [.mealImage]
        )
        let speechRevocation = CloudHealthContextPolicyChange(
            provider: .qwen,
            snapshot: snapshot,
            revokedClasses: [.speechAudio]
        )
        let sleepRevocation = CloudHealthContextPolicyChange(
            provider: .qwen,
            snapshot: snapshot,
            revokedClasses: [.healthSleep]
        )
        let activityRevocation = CloudHealthContextPolicyChange(
            provider: .qwen,
            snapshot: snapshot,
            revokedClasses: [.healthActivity]
        )
        XCTAssertFalse(imageRevocation.affects(requestDataClasses: textDependencies))
        XCTAssertFalse(speechRevocation.affects(requestDataClasses: textDependencies))
        XCTAssertTrue(imageRevocation.affects(requestDataClasses: imageDependencies))
        XCTAssertTrue(sleepRevocation.affects(requestDataClasses: sleepDependencies))
        XCTAssertTrue(activityRevocation.affects(requestDataClasses: goalDependencies))
    }

    func testGranularConsentPersistsPerProviderAndDefaultsToDenied() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)

        let initial = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)
        XCTAssertTrue(initial.allowedClasses.isEmpty)

        _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthActivity],
            repository: repository,
            changeSource: .settings
        )
        let updated = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)
        XCTAssertEqual(updated.allowedClasses, [.healthActivity])
        XCTAssertNotEqual(updated.revision, initial.revision)

        let otherProvider = try await CloudHealthContextPolicy.load(from: repository, provider: .qwen)
        XCTAssertTrue(otherProvider.allowedClasses.isEmpty)

        _ = try await CloudHealthContextPolicy.applyRestrictiveChange(
            provider: .deepSeek,
            allowedClasses: [],
            repository: repository,
            changeSource: .settings
        )
        let revoked = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)
        XCTAssertFalse(revoked.allows(.healthActivity))
        XCTAssertEqual(revoked.allowedClasses, [])
        XCTAssertNotEqual(revoked.revision, updated.revision)
    }

    func testPerClassRevocationPersistsMatchingConsentAndPolicySnapshot() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthActivity, .healthSleep],
            repository: repository,
            confirmedAt: Date(timeIntervalSince1970: 1_798_000_000),
            changeSource: .settings
        )

        let revokedSnapshot = try await CloudHealthContextPolicy.applyRestrictiveChange(
            provider: .deepSeek,
            allowedClasses: [.healthSleep],
            repository: repository,
            changeSource: .settings
        )
        let persistedSnapshot = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        let activityConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthActivity)
        let sleepConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthSleep)

        XCTAssertFalse(activityConsent)
        XCTAssertTrue(sleepConsent)
        XCTAssertEqual(revokedSnapshot.allowedClasses, [.healthSleep])
        XCTAssertEqual(persistedSnapshot.allowedClasses, [.healthSleep])
        XCTAssertEqual(persistedSnapshot.revision, revokedSnapshot.revision)
    }

    func testPolicySnapshotPersistsMonotonicRevisionHashAndRequiresConfirmedExpansion() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let initial = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)

        XCTAssertEqual(initial.schemaVersion, CloudHealthContextPolicySnapshot.currentSchemaVersion)
        XCTAssertEqual(initial.state, .notConfigured)
        XCTAssertEqual(initial.revision, 0)
        XCTAssertTrue(initial.allowedClasses.isEmpty)

        let firstConfirmedAt = Date(timeIntervalSince1970: 1_798_000_000)
        let first = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthSleep],
            repository: repository,
            confirmedAt: firstConfirmedAt,
            changeSource: .onboarding
        )
        XCTAssertEqual(first.state, .active)
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.confirmedAt, firstConfirmedAt)
        XCTAssertNotEqual(first.policyHash, initial.policyHash)

        do {
            _ = try await CloudHealthContextPolicy.applyRestrictiveChange(
                provider: .deepSeek,
                allowedClasses: [.healthSleep, .healthActivity],
                repository: repository
            )
            XCTFail("Expanding a policy must require an explicit confirmation")
        } catch {
            XCTAssertEqual(error as? CloudHealthContextPolicyError, .expansionRequiresConfirmation)
        }

        let expanded = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthSleep, .healthActivity],
            repository: repository,
            confirmedAt: firstConfirmedAt.addingTimeInterval(60),
            changeSource: .settings
        )
        XCTAssertEqual(expanded.revision, 2)
        XCTAssertEqual(expanded.policyID, first.policyID)
        XCTAssertNotEqual(expanded.policyHash, first.policyHash)

        let revoked = try await CloudHealthContextPolicy.applyRestrictiveChange(
            provider: .deepSeek,
            allowedClasses: [],
            repository: repository
        )
        XCTAssertEqual(revoked.state, .revoked)
        XCTAssertEqual(revoked.allowedClasses, [])
        XCTAssertEqual(revoked.revision, 3)
        XCTAssertNotEqual(revoked.policyHash, expanded.policyHash)
    }

    func testLegacyCoarseHealthTextConsentDoesNotEnableGranularHealthContext() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let legacyContext = ModelContext(container)
        legacyContext.insert(ConsentRecord(
            consentKey: "provider|deepSeek|healthText",
            kind: ProviderDataClass.healthText.rawValue,
            policyVersion: "cloud-health-text-v1",
            granted: true,
            decidedAt: Date(timeIntervalSince1970: 1_798_000_000)
        ))
        try legacyContext.save()

        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let snapshot = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)

        XCTAssertEqual(snapshot.state, .notConfigured)
        XCTAssertTrue(snapshot.allowedClasses.isEmpty)
        XCTAssertEqual(snapshot.changeSource, .legacyConsent)
    }

    func testPolicySnapshotIntersectsReadsWhenConsentIsRevokedMidLoad() async throws {
        let repository = RevokesSleepConsentDuringSnapshotRepository()

        let policy = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)

        XCTAssertFalse(policy.allows(.healthSleep))
        XCTAssertTrue(policy.allows(.healthActivity))
    }

    func testFinalProviderSendRejectsRevokedAndReconfirmedPolicyRevision() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthSleep],
            repository: repository,
            confirmedAt: Date(timeIntervalSince1970: 1_798_300_000),
            changeSource: .settings
        )
        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .healthText,
            granted: true,
            policyVersion: "cloud-health-text-v1"
        )
        let expectedPolicy = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)
        XCTAssertTrue(expectedPolicy.allows(.healthSleep))

        _ = try await CloudHealthContextPolicy.applyRestrictiveChange(
            provider: .deepSeek,
            allowedClasses: [],
            repository: repository,
            changeSource: .settings
        )
        _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthSleep],
            repository: repository,
            confirmedAt: Date(timeIntervalSince1970: 1_798_300_060),
            changeSource: .settings
        )

        do {
            _ = try await CloudHealthContextPolicy.withCurrentSendConsent(
                from: repository,
                provider: .deepSeek,
                expectedHealthPolicy: expectedPolicy,
                includesImage: false,
                operation: { true }
            )
            XCTFail("A stale policy revision must not start a provider request after reconfirmation")
        } catch {
            let policyChanged = error as? ProviderError
            XCTAssertEqual(policyChanged, .consentPolicyChanged(provider: .deepSeek))
            XCTAssertEqual(policyChanged?.sharedErrorDescriptor.reason, .consentPolicyChanged)
        }

        do {
            _ = try await CloudHealthContextPolicy.withCurrentSendConsentSerialization(
                from: repository,
                provider: .deepSeek,
                expectedHealthPolicy: expectedPolicy,
                includesImage: false,
                operation: { Data("stale-private-payload".utf8) }
            )
            XCTFail("A stale policy must not serialize a provider payload")
        } catch {
            XCTAssertEqual(error as? ProviderError, .consentPolicyChanged(provider: .deepSeek))
        }
    }

    func testImageConsentReconfirmationAdvancesTheFinalSendPolicyRevision() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let initial = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)

        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .mealImage,
            granted: true,
            policyVersion: "deepseek-sanitized-meal-image-v1"
        )
        let firstGrant = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .mealImage,
            granted: false,
            policyVersion: "deepseek-sanitized-meal-image-v1"
        )
        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .mealImage,
            granted: true,
            policyVersion: "deepseek-sanitized-meal-image-v1"
        )
        let reconfirmed = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)

        XCTAssertEqual(firstGrant.revision, initial.revision + 1)
        XCTAssertEqual(reconfirmed.revision, firstGrant.revision + 2)
        XCTAssertEqual(reconfirmed.allowedClasses, initial.allowedClasses)
    }

    func testImageRequestPersistsHealthRevocationBeforeProviderSerialization() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let governance = SwiftDataProviderGovernanceRepository(modelContainer: container)
        try await governance.setConsent(
            provider: .deepSeek,
            dataClass: .healthText,
            granted: true,
            policyVersion: "cloud-health-text-v1"
        )
        try await governance.setConsent(
            provider: .deepSeek,
            dataClass: .mealImage,
            granted: true,
            policyVersion: "deepseek-sanitized-meal-image-v1"
        )
        let initialPolicy = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthSleep, .healthActivity],
            repository: governance,
            confirmedAt: Date(timeIntervalSince1970: 1_798_400_000),
            changeSource: .settings
        )

        let provider = ScriptedTextProvider(
            scripts: [[.textDelta("已在更新后的授权策略下处理图片。"), .completed(.completed)]],
            capabilities: [.text, .toolCalling, .structuredOutput, .vision]
        )
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let preferences = IntelligencePreferences()
        preferences.mode = .cloudDeepSeek
        let confirmationRepository = SwiftDataConfirmationRepository(modelContainer: container)
        let session = AgentSession(
            providerSelector: TestProviderSelector(provider),
            intelligencePreferences: preferences,
            providerConfiguration: ProviderConfigurationPreferences(),
            governanceRepository: governance,
            usageLedger: ProviderUsageLedger(repository: governance),
            registry: ToolRegistry(),
            confirmationCoordinator: ConfirmationCoordinator(
                repository: confirmationRepository,
                writeGate: PersistenceWriteGate(state: .writable)
            ),
            readRepository: repository,
            conversationRepository: repository,
            conversationID: UUID(),
            budgetFactory: { AgentBudget(deadline: .distantFuture) }
        )

        let response = try await session.send(
            multimodalRequest: try MultimodalModelRequest(
                userText: "识别图片里的午餐，不要上传睡眠数据。",
                imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                mealEvidence: []
            ),
            requestID: UUID()
        )

        XCTAssertTrue(response.text.contains("已立即撤销睡眠类别"))
        XCTAssertTrue(response.text.contains("更新后的授权策略"))
        let currentPolicy = try await CloudHealthContextPolicy.load(from: governance, provider: .deepSeek)
        XCTAssertEqual(currentPolicy.allowedClasses, [.healthActivity])
        XCTAssertEqual(currentPolicy.snapshot.revision, initialPolicy.revision + 1)

        let request = try XCTUnwrap(provider.recordedRequests().first)
        XCTAssertTrue(request.messages.contains { message in
            message.content.contains { content in
                if case .image = content { return true }
                return false
            }
        })
        let serializationGate = try XCTUnwrap(request.preSerializationGate)
        let serialized = try await serializationGate { Data("current-policy-body".utf8) }
        XCTAssertEqual(String(decoding: serialized, as: UTF8.self), "current-policy-body")
        let networkAttemptGate = try XCTUnwrap(request.networkAttemptGate)
        try await networkAttemptGate()
        try await networkAttemptGate()
    }

    func testImageRequestCannotBypassHealthExpansionConfirmation() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let governance = SwiftDataProviderGovernanceRepository(modelContainer: container)
        try await governance.setConsent(
            provider: .deepSeek,
            dataClass: .healthText,
            granted: true,
            policyVersion: "cloud-health-text-v1"
        )
        try await governance.setConsent(
            provider: .deepSeek,
            dataClass: .mealImage,
            granted: true,
            policyVersion: "deepseek-sanitized-meal-image-v1"
        )
        let provider = ScriptedTextProvider(
            scripts: [],
            capabilities: [.text, .toolCalling, .structuredOutput, .vision]
        )
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let preferences = IntelligencePreferences()
        preferences.mode = .cloudDeepSeek
        let session = AgentSession(
            providerSelector: TestProviderSelector(provider),
            intelligencePreferences: preferences,
            providerConfiguration: ProviderConfigurationPreferences(),
            governanceRepository: governance,
            usageLedger: ProviderUsageLedger(repository: governance),
            registry: ToolRegistry(),
            confirmationCoordinator: ConfirmationCoordinator(
                repository: SwiftDataConfirmationRepository(modelContainer: container),
                writeGate: PersistenceWriteGate(state: .writable)
            ),
            readRepository: repository,
            conversationRepository: repository,
            conversationID: UUID(),
            budgetFactory: { AgentBudget(deadline: .distantFuture) }
        )

        let response = try await session.send(
            multimodalRequest: try MultimodalModelRequest(
                userText: "允许使用睡眠数据并识别这张晚餐图片。",
                imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                mealEvidence: []
            ),
            requestID: UUID()
        )

        XCTAssertTrue(response.text.contains("回复“确认”启用"))
        let draft = try await governance.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        XCTAssertEqual(draft.state, .draft)
        XCTAssertEqual(draft.allowedClasses, [.healthSleep])
        let effectivePolicy = try await CloudHealthContextPolicy.load(from: governance, provider: .deepSeek)
        XCTAssertFalse(effectivePolicy.allows(.healthSleep))
        XCTAssertTrue(provider.recordedRequests().isEmpty)
    }

    func testUnconfiguredPolicyOmitsAutomaticHistoricalContext() {
        let policy = CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [])
        let context = makeContext()

        XCTAssertNil(CloudRequestPolicyGuard.filtered(context, by: policy))
        XCTAssertFalse(policy.allows(.healthSleep))
        XCTAssertFalse(policy.allows(.healthActivity))
    }

    func testSummaryKeepsOnlyAuthorizedCategoriesAndDropsCrossDomainDerivations() {
        let policy = CloudHealthContextPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthSleep, .healthActivity]
        )
        let filtered = CloudRequestPolicyGuard.filtered(makeContext(), by: policy)

        XCTAssertEqual(filtered?.aggregateSummary?.sevenDay.averageSleepMinutes, 420)
        XCTAssertEqual(filtered?.aggregateSummary?.sevenDay.averageStepCount, 8_000)
        XCTAssertNil(filtered?.aggregateSummary?.sevenDay.averageEnergyIntakeKcal)
        XCTAssertNil(filtered?.aggregateSummary?.sevenDay.medianWeightKilograms)
        XCTAssertNil(filtered?.aggregateSummary?.sevenDay.averageDailyDeficitKcal)
        XCTAssertEqual(
            Set(filtered?.aggregateSummary?.sevenDay.coverageDays.keys.map { $0 } ?? []),
            Set(["sleep", "steps"])
        )
        XCTAssertEqual(filtered?.healthState?.recovery.status, .insufficientEvidence)
        XCTAssertNil(filtered?.healthState?.tomorrowGuidance)
        XCTAssertEqual(filtered?.healthState?.trainingLoad.band, .nearTypical)

        let sleepOnlyPolicy = CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [.healthSleep])
        let sleepOnly = CloudRequestPolicyGuard.filtered(makeContext(), by: sleepOnlyPolicy)
        XCTAssertNil(sleepOnly?.healthState)
        XCTAssertNil(sleepOnly?.aggregateSummary?.sevenDay.averageStepCount)
        XCTAssertNil(sleepOnly?.aggregateSummary?.sevenDay.averageActiveEnergyKcal)
        XCTAssertNil(sleepOnly?.aggregateSummary?.sevenDay.averageEnergyIntakeKcal)
        XCTAssertEqual(
            Set(sleepOnly?.aggregateSummary?.sevenDay.coverageDays.keys.map { $0 } ?? []),
            Set(["sleep"])
        )
    }

    func testSummaryPreservesOnlyAuthorizedPerMetricWindowCoverage() {
        let start = Date(timeIntervalSince1970: 1_798_000_000)
        let end = start.addingTimeInterval(41 * 24 * 60 * 60)
        let metricCoverage = Dictionary(uniqueKeysWithValues: [
            "sleep", "steps", "activeEnergy", "energyIntake", "dailyDeficitKcal", "proteinGrams", "bodyMass",
        ].map { key in
            (key, HealthMetricWindowCoverage(
                targetWindowStart: start,
                targetWindowEnd: end,
                expectedCalendarDays: 42,
                actualEarliestDate: start,
                validCalendarDays: 30,
                missingCalendarDays: 12,
                authorizationLimited: true,
                dataAvailabilityLimited: false
            ))
        })
        let window = HealthContextWindowSummary(
            windowDays: 28,
            coverageDays: Dictionary(uniqueKeysWithValues: metricCoverage.keys.map { ($0, 10) }),
            averageSleepMinutes: 420,
            averageStepCount: 8_000,
            averageActiveEnergyKcal: 500,
            averageEnergyIntakeKcal: 1_900,
            averageDailyDeficitKcal: 300,
            averageProteinGrams: 90,
            medianWeightKilograms: 68,
            metricWindowCoverage: metricCoverage
        )
        let summary = HealthContextSummary(
            sevenDay: window,
            twentyEightDay: window,
            targetWeightKilograms: 65,
            dailyDeficitGoalKcal: 300,
            dailyProteinGoalGrams: 100,
            recommendationReferences: [],
            analysisWindowCoverage: metricCoverage
        )

        let activityAndSleep = CloudRequestPolicyGuard.filtered(
            summary,
            by: CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [.healthSleep, .healthActivity])
        )
        let expectedActivityAndSleep = Set(["sleep", "steps", "activeEnergy"])
        XCTAssertEqual(Set(activityAndSleep.analysisWindowCoverage.keys), expectedActivityAndSleep)
        XCTAssertEqual(Set(activityAndSleep.sevenDay.metricWindowCoverage.keys), expectedActivityAndSleep)
        XCTAssertEqual(Set(activityAndSleep.twentyEightDay.metricWindowCoverage.keys), expectedActivityAndSleep)
        XCTAssertEqual(activityAndSleep.analysisWindowCoverage["sleep"]?.validCalendarDays, 30)
        XCTAssertNil(activityAndSleep.analysisWindowCoverage["proteinGrams"])
        XCTAssertNil(activityAndSleep.analysisWindowCoverage["dailyDeficitKcal"])

        let nutritionAndActivity = CloudRequestPolicyGuard.filtered(
            summary,
            by: CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [.healthNutrition, .healthActivity])
        )
        XCTAssertEqual(
            Set(nutritionAndActivity.analysisWindowCoverage.keys),
            Set(["steps", "activeEnergy", "energyIntake", "dailyDeficitKcal", "proteinGrams"])
        )
        XCTAssertNotNil(nutritionAndActivity.analysisWindowCoverage["proteinGrams"])
        XCTAssertNotNil(nutritionAndActivity.analysisWindowCoverage["dailyDeficitKcal"])
        XCTAssertNil(nutritionAndActivity.analysisWindowCoverage["sleep"])
        XCTAssertNil(nutritionAndActivity.analysisWindowCoverage["bodyMass"])
    }

    func testCurrentTurnAssistantTextIsRemovedBeforeRestrictedContinuation() throws {
        let toolCall = ToolCall(id: "health-history", name: "get_health_history", arguments: .object([:]))
        let messages = [
            ModelMessage(role: .user, text: "之前的问题"),
            ModelMessage(role: .assistant, text: "previous health answer"),
            ModelMessage(role: .user, text: "继续查询"),
            ModelMessage(role: .assistant, content: [
                .text("sleep.current-round-secret"),
                .toolCall(toolCall),
                .reasoning(.string("sleep.reasoning-secret")),
            ]),
        ]

        let filtered = CloudRequestPolicyGuard.filterConversationHistory(
            messages,
            currentTurnStartIndex: 2,
            by: CloudHealthContextPolicy(
                provider: .deepSeek,
                allowedClasses: [.healthActivity],
                allowsConversationHistory: true
            )
        )
        let currentTurn = Array(filtered.suffix(2))
        XCTAssertEqual(currentTurn.first?.role, .user)
        XCTAssertEqual(currentTurn.first?.content, [.text("继续查询")])
        XCTAssertEqual(currentTurn.count, 2)
        XCTAssertEqual(currentTurn[1].content, [.toolCall(toolCall)])
        let serializedCurrentTurn = String(describing: currentTurn)
        XCTAssertFalse(serializedCurrentTurn.contains("sleep.current-round-secret"))
        XCTAssertFalse(serializedCurrentTurn.contains("sleep.reasoning-secret"))
    }

    func testPastHealthNarrativeWithRevokedPolicyProvenanceIsRemovedForGenericUserWording() throws {
        let messages = [
            ModelMessage(role: .user, text: "好的"),
            ModelMessage(
                role: .assistant,
                text: "这周的睡眠覆盖了七天，sleep.provenance-secret。",
                healthContextPolicyProvenance: HealthContextPolicyProvenance(
                    provider: .deepSeek,
                    policyRevision: "deepSeek:4:sleep-activity-policy-hash",
                    allowedClasses: [.healthSleep, .healthActivity]
                )
            ),
            ModelMessage(role: .user, text: "继续")
        ]

        let filtered = CloudRequestPolicyGuard.filterConversationHistory(
            messages,
            currentTurnStartIndex: 2,
            by: CloudHealthContextPolicy(
                provider: .deepSeek,
                allowedClasses: [.healthActivity],
                allowsConversationHistory: true
            )
        )

        XCTAssertEqual(filtered.map(\.role), [.user])
        XCTAssertFalse(String(describing: filtered).contains("sleep.provenance-secret"))
    }

    func testPastUnprovenancedAssistantNarrativeFailsClosedForGenericWording() throws {
        let messages = [
            ModelMessage(role: .user, text: "继续"),
            ModelMessage(role: .assistant, text: "这里是昨天的数字 12345。"),
            ModelMessage(role: .user, text: "下一步"),
        ]

        let filtered = CloudRequestPolicyGuard.filterConversationHistory(
            messages,
            currentTurnStartIndex: 2,
            by: CloudHealthContextPolicy(
                provider: .deepSeek,
                allowedClasses: [.healthActivity],
                allowsConversationHistory: true
            )
        )

        XCTAssertEqual(filtered.map(\.role), [.user])
        XCTAssertFalse(String(describing: filtered).contains("12345"))
    }

    func testPolicyRevisionChangeDoesNotRestorePreviouslyRevokedNarrativeAfterReconfirmation() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthSleep],
            repository: repository,
            confirmedAt: Date(timeIntervalSince1970: 1_798_100_000),
            changeSource: .settings
        )
        _ = try await CloudHealthContextPolicy.updateConversationHistoryConsent(
            provider: .deepSeek,
            allowed: true,
            repository: repository,
            confirmedAt: Date(timeIntervalSince1970: 1_798_100_030),
            changeSource: .settings
        )
        let originalPolicy = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)
        XCTAssertTrue(originalPolicy.allowsConversationHistory)
        let messages = [
            ModelMessage(role: .user, text: "好的"),
            ModelMessage(
                role: .assistant,
                text: "睡眠信息 sleep.revoked-then-reconfirmed-secret。",
                healthContextPolicyProvenance: HealthContextPolicyProvenance(
                    provider: .deepSeek,
                    policyRevision: originalPolicy.revision,
                    allowedClasses: originalPolicy.allowedClasses
                )
            ),
            ModelMessage(role: .user, text: "继续"),
        ]

        _ = try await CloudHealthContextPolicy.applyRestrictiveChange(
            provider: .deepSeek,
            allowedClasses: [],
            repository: repository,
            changeSource: .settings
        )
        _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthSleep],
            repository: repository,
            confirmedAt: Date(timeIntervalSince1970: 1_798_100_060),
            changeSource: .settings
        )
        let reconfirmedPolicy = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)
        XCTAssertEqual(reconfirmedPolicy.allowedClasses, [.healthSleep])
        XCTAssertTrue(reconfirmedPolicy.allowsConversationHistory)
        XCTAssertNotEqual(reconfirmedPolicy.revision, originalPolicy.revision)

        let filtered = CloudRequestPolicyGuard.filterConversationHistory(
            messages,
            currentTurnStartIndex: 2,
            by: reconfirmedPolicy
        )
        XCTAssertEqual(filtered.map(\.role), [.user])
        XCTAssertFalse(String(describing: filtered).contains("sleep.revoked-then-reconfirmed-secret"))
    }

    func testConversationAlignmentRequiresExplicitOptInAndSeparatesRevocation() {
        XCTAssertNil(CloudHealthContextPolicyAlignmentIntent.parse("看看我的睡眠数据"))
        XCTAssertEqual(
            CloudHealthContextPolicyAlignmentIntent.parse("我同意你使用睡眠和活动历史"),
            .requestExpansion([.healthSleep, .healthActivity])
        )
        XCTAssertEqual(
            CloudHealthContextPolicyAlignmentIntent.parse("不再使用睡眠历史"),
            .revoke([.healthSleep])
        )
        XCTAssertEqual(CloudHealthContextPolicyAlignmentIntent.parse("确认。"), .confirm)
    }

    func testConversationHistoryIsProviderScopedIndependentAndRevisionBound() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .healthText,
            granted: true,
            policyVersion: "cloud-health-text-v1"
        )

        let defaultPolicy = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)
        XCTAssertFalse(defaultPolicy.allowsConversationHistory)
        do {
            _ = try await CloudHealthContextPolicy.updateConversationHistoryConsent(
                provider: .deepSeek,
                allowed: true,
                repository: repository
            )
            XCTFail("Conversation history expansion must require explicit confirmation")
        } catch {
            XCTAssertEqual(error as? CloudHealthContextPolicyError, .expansionRequiresConfirmation)
        }

        _ = try await CloudHealthContextPolicy.updateConversationHistoryConsent(
            provider: .deepSeek,
            allowed: true,
            repository: repository,
            confirmedAt: Date(timeIntervalSince1970: 1_798_200_000),
            changeSource: .settings
        )
        let allowedPolicy = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)
        XCTAssertTrue(allowedPolicy.allowsConversationHistory)
        XCTAssertTrue(allowedPolicy.allowedClasses.isEmpty)
        let qwenPolicy = try await CloudHealthContextPolicy.load(from: repository, provider: .qwen)
        XCTAssertFalse(qwenPolicy.allowsConversationHistory)

        let history = [
            ModelMessage(
                role: .user,
                text: "previous private user note",
                healthContextPolicyProvenance: HealthContextPolicyProvenance(
                    provider: .deepSeek,
                    policyRevision: allowedPolicy.revision,
                    allowedClasses: allowedPolicy.allowedClasses
                )
            ),
            ModelMessage(
                role: .assistant,
                text: "previous assistant note",
                healthContextPolicyProvenance: HealthContextPolicyProvenance(
                    provider: .deepSeek,
                    policyRevision: allowedPolicy.revision,
                    allowedClasses: allowedPolicy.allowedClasses
                )
            ),
            ModelMessage(
                role: .user,
                text: "current question",
                healthContextPolicyProvenance: HealthContextPolicyProvenance(
                    provider: .deepSeek,
                    policyRevision: allowedPolicy.revision,
                    allowedClasses: allowedPolicy.allowedClasses
                )
            ),
        ]
        let forwarded = CloudRequestPolicyGuard.filterConversationHistory(
            history,
            currentTurnStartIndex: 2,
            by: allowedPolicy
        )
        XCTAssertTrue(String(describing: forwarded).contains("previous private user note"))

        _ = try await CloudHealthContextPolicy.updateConversationHistoryConsent(
            provider: .deepSeek,
            allowed: false,
            repository: repository,
            changeSource: .settings
        )
        let revokedPolicy = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)
        XCTAssertFalse(revokedPolicy.allowsConversationHistory)
        XCTAssertNotEqual(revokedPolicy.revision, allowedPolicy.revision)
        let afterRevocation = CloudRequestPolicyGuard.filterConversationHistory(
            history,
            currentTurnStartIndex: 2,
            by: revokedPolicy
        )
        XCTAssertEqual(afterRevocation.map(\.role), [.user])
        XCTAssertFalse(String(describing: afterRevocation).contains("previous private user note"))
    }

    func testProviderContinuationRemovesForbiddenSleepAndSleepDerivedRecovery() throws {
        let policy = CloudHealthContextPolicy(
            provider: .qwen,
            allowedClasses: [.healthActivity]
        )
        let payload = #"{"status":"available","healthState":{"domains":[{"domain":"sleep","currentValue":999,"evidenceKeys":["sleep-secret"]},{"domain":"activity","currentValue":123,"evidenceKeys":["activity-visible"]}],"recovery":{"status":"attention","evidence":[{"key":"sleep-secret","source":"sleep"}]},"trainingLoad":{"recentSevenDayLoad":123,"band":"increased"},"tomorrowGuidance":{"conditionalNote":"sleep-secret"}},"evidenceReferences":[{"key":"sleep-secret","source":"sleep"},{"key":"activity-visible","source":"activity"}]}"#
        let messages = [
            ModelMessage(role: .assistant, content: [
                .toolCall(ToolCall(id: "health-state", name: "get_today_health_state", arguments: .object([:])))
            ]),
            ModelMessage(role: .tool, content: [
                .toolResult(toolCallID: "health-state", content: payload)
            ]),
        ]

        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        let sentContent = filtered.flatMap(\.content).compactMap { content -> String? in
            if case .toolResult(_, let value) = content { return value }
            return nil
        }.joined()

        XCTAssertTrue(sentContent.contains("activity-visible"))
        XCTAssertTrue(sentContent.contains("123"))
        XCTAssertFalse(sentContent.contains("sleep-secret"))
        XCTAssertFalse(sentContent.contains("999"))
        XCTAssertFalse(sentContent.contains("\"status\":\"attention\""))
    }

    func testGoalContinuationOmitsDailyDeficitWhenActivityIsNotAuthorized() throws {
        let policy = CloudHealthContextPolicy(
            provider: .qwen,
            allowedClasses: [.healthNutrition, .healthBody]
        )
        let payload = #"{"status":"available","asOf":"2026-10-01","goal":{"effectiveFrom":"2026-09-01","targetWeightKilograms":58,"dailyDeficitKcal":300,"dailyProteinGrams":100},"message":"local goal profile"}"#
        let messages = [
            ModelMessage(role: .assistant, content: [
                .toolCall(ToolCall(id: "goal", name: "get_goal", arguments: .object([:]))),
            ]),
            ModelMessage(role: .tool, content: [
                .toolResult(toolCallID: "goal", content: payload),
            ]),
        ]

        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        guard case .toolResult(_, let result)? = filtered.last?.content.first,
              let data = result.data(using: .utf8),
              let json = try JSONDecoder().decode(JSONValue.self, from: data).objectValue,
              let goal = json["goal"]?.objectValue else {
            return XCTFail("Expected a category-filtered goal result")
        }

        XCTAssertEqual(json["status"]?.stringValue, "available")
        XCTAssertEqual(goal["targetWeightKilograms"]?.doubleValue, 58)
        XCTAssertEqual(goal["dailyProteinGrams"]?.doubleValue, 100)
        XCTAssertNil(goal["dailyDeficitKcal"])
        XCTAssertFalse(result.contains("dailyDeficitKcal"))
        XCTAssertFalse(result.contains("300"))
    }

    func testFinalHealthHistoryContinuationFailsClosedForEveryDeniedClassSentinel() throws {
        let scenarios: [(
            denied: ProviderDataClass,
            sentinels: [String],
            allowedSentinel: String,
            removesDerivedRecovery: Bool,
            removesTrainingLoad: Bool
        )] = [
            (
                .healthNutrition,
                [
                    "nutrition-status-sentinel",
                    "nutrition.value.SENTINEL",
                    "nutrition.derived.SENTINEL",
                    "10101",
                    "10102",
                ],
                "sleep.value.SENTINEL",
                false,
                false
            ),
            (
                .healthSleep,
                ["sleep-status-sentinel", "sleep.value.SENTINEL", "sleep.derived.SENTINEL", "20201", "20202"],
                "activity.value.SENTINEL",
                true,
                false
            ),
            (
                .healthActivity,
                [
                    "activity-status-sentinel",
                    "activity.value.SENTINEL",
                    "activity.derived.SENTINEL",
                    "trainingLoad.derived.SENTINEL",
                    "30301",
                    "30302",
                    "30303",
                ],
                "body.value.SENTINEL",
                true,
                true
            ),
            (
                .healthBody,
                ["body-status-sentinel", "body.value.SENTINEL", "body.derived.SENTINEL", "40401", "40402"],
                "nutrition.value.SENTINEL",
                true,
                false
            ),
            (
                .healthSubjective,
                ["subjective-status-sentinel", "subjective.value.SENTINEL", "subjective.derived.SENTINEL", "50501", "50502"],
                "activity.value.SENTINEL",
                false,
                false
            ),
        ]
        let payloadObject: [String: Any] = [
            "status": "available",
            "message": "unfiltered-root-message-sentinel",
            "startDate": "2026-10-01",
            "endDate": "2026-10-01",
            "days": [[
                "date": "2026-10-01",
                "domainStatuses": [
                    "nutrition": "nutrition-status-sentinel",
                    "sleep": "sleep-status-sentinel",
                    "activity": "activity-status-sentinel",
                    "body": "body-status-sentinel",
                    "subjective": "subjective-status-sentinel",
                ],
                "observations": [
                    "nutrition.value.SENTINEL": 10101,
                    "nutrition.derived.SENTINEL": 10102,
                    "sleep.value.SENTINEL": 20201,
                    "sleep.derived.SENTINEL": 20202,
                    "activity.value.SENTINEL": 30301,
                    "activity.derived.SENTINEL": 30302,
                    "trainingLoad.derived.SENTINEL": 30303,
                    "body.value.SENTINEL": 40401,
                    "body.derived.SENTINEL": 40402,
                    "subjective.value.SENTINEL": 50501,
                    "subjective.derived.SENTINEL": 50502,
                ],
                "recoveryStatus": "recovery.derived.SENTINEL",
                "trainingLoadBand": "trainingLoad.derived.SENTINEL",
            ]],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
        let payload = String(decoding: payloadData, as: UTF8.self)

        for provider in [ProviderID.deepSeek, .qwen] {
            for scenario in scenarios {
                let allowed = Set(CloudHealthContextPolicy.dataClasses).subtracting([scenario.denied])
                let policy = CloudHealthContextPolicy(provider: provider, allowedClasses: allowed)
                let callID = "history-\(provider.rawValue)-\(scenario.denied.rawValue)"
                let messages = [
                    ModelMessage(role: .assistant, content: [
                        .toolCall(ToolCall(id: callID, name: "get_health_history", arguments: .object([:])))
                    ]),
                    ModelMessage(role: .tool, content: [
                        .toolResult(toolCallID: callID, content: payload)
                    ]),
                ]

                let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
                guard case .toolResult(_, let result)? = filtered.last?.content.first else {
                    return XCTFail("Expected final filtered tool result for \(provider.rawValue), denied \(scenario.denied.rawValue)")
                }

                for sentinel in scenario.sentinels {
                    XCTAssertFalse(
                        result.localizedCaseInsensitiveContains(sentinel),
                        "Denied \(scenario.denied.rawValue) sentinel leaked for \(provider.rawValue): \(sentinel)"
                    )
                }
                XCTAssertTrue(
                    result.localizedCaseInsensitiveContains(scenario.allowedSentinel),
                    "An allowed category should remain for \(provider.rawValue) when denying \(scenario.denied.rawValue)"
                )
                if scenario.removesDerivedRecovery {
                    XCTAssertFalse(result.contains("recovery.derived.SENTINEL"))
                }
                if scenario.removesTrainingLoad {
                    XCTAssertFalse(result.contains("trainingLoad.derived.SENTINEL"))
                }
                XCTAssertFalse(result.contains("unfiltered-root-message-sentinel"))
            }
        }
    }

    func testProviderContinuationOmitsTrainingLoadWhenActivityIsNotAuthorized() throws {
        let policy = CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [.healthSleep])
        let payload = #"{"status":"available","healthState":{"domains":[{"domain":"sleep","currentValue":420,"evidenceKeys":["sleep-visible"]},{"domain":"activity","currentValue":9876,"evidenceKeys":["activity-secret"]}],"recovery":{"status":"attention","evidence":[{"key":"sleep-visible","source":"sleep"}]},"trainingLoad":{"recentSevenDayLoad":555,"estimatedWorkoutCount":12,"band":"increased"}}}"#
        let messages = [
            ModelMessage(role: .assistant, content: [
                .toolCall(ToolCall(id: "health-state", name: "get_today_health_state", arguments: .object([:])))
            ]),
            ModelMessage(role: .tool, content: [
                .toolResult(toolCallID: "health-state", content: payload)
            ]),
        ]

        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        let sentContent = filtered.flatMap(\.content).compactMap { content -> String? in
            if case .toolResult(_, let value) = content { return value }
            return nil
        }.joined()

        XCTAssertTrue(sentContent.contains("sleep-visible"))
        XCTAssertFalse(sentContent.contains("activity-secret"))
        XCTAssertFalse(sentContent.contains("9876"))
        XCTAssertFalse(sentContent.contains("555"))
        XCTAssertFalse(sentContent.contains("estimatedWorkoutCount"))
        XCTAssertFalse(sentContent.contains("trainingLoad"))
    }

    func testHealthHistoryRecomputesStatusFromAuthorizedFieldsAndDropsForbiddenOnlyDates() throws {
        let policy = CloudHealthContextPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthActivity],
            allowsConversationHistory: true
        )
        let payload = #"{"status":"available","message":"sleep data was available","startDate":"2026-10-01","endDate":"2026-10-02","days":[{"date":"2026-10-01","domainStatuses":{"sleep":"attention"},"observations":{"sleep.mainSleep.minutes":999},"recoveryStatus":"attention"},{"date":"2026-10-02","domainStatuses":{"activity":"noData"},"observations":{},"recoveryStatus":"attention","trainingLoadBand":"unavailable"}]}"#
        let messages = [
            ModelMessage(role: .assistant, content: [
                .toolCall(ToolCall(id: "history", name: "get_health_history", arguments: .object([:])))
            ]),
            ModelMessage(role: .tool, content: [
                .toolResult(toolCallID: "history", content: payload)
            ]),
        ]

        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        guard case .toolResult(_, let result)? = filtered.last?.content.first,
              let data = result.data(using: .utf8),
              let json = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            return XCTFail("Expected filtered history JSON")
        }
        let days = json["days"]?.arrayValue ?? []

        XCTAssertEqual(json["status"]?.stringValue, "noData")
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.objectValue?["date"]?.stringValue, "2026-10-02")
        XCTAssertFalse(result.contains("sleep"))
        XCTAssertFalse(result.contains("999"))
        XCTAssertTrue(result.contains("已授权类别没有可用观测"))
    }

    func testAuthorizedUnknownHealthHistoryCoverageDoesNotBecomeNoDataOrZero() throws {
        let policy = CloudHealthContextPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthActivity],
            allowsConversationHistory: true
        )
        let payload = #"{"status":"noData","message":"no observations","startDate":"2026-10-01","endDate":"2026-10-02","days":[{"date":"2026-10-01","domainStatuses":{"activity":"unknown","sleep":"attention"},"observations":{"sleep.mainSleep.minutes":9876543}},{"date":"2026-10-02","domainStatuses":{"activity":"partial","sleep":"attention"},"observations":{"sleep.mainSleep.minutes":9876543}}]}"#
        let messages = [
            ModelMessage(role: .assistant, content: [
                .toolCall(ToolCall(id: "history", name: "get_health_history", arguments: .object([:])))
            ]),
            ModelMessage(role: .tool, content: [
                .toolResult(toolCallID: "history", content: payload)
            ]),
        ]

        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        guard case .toolResult(_, let result)? = filtered.last?.content.first,
              let data = result.data(using: .utf8),
              let json = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            return XCTFail("Expected filtered history JSON")
        }
        let days = json["days"]?.arrayValue ?? []

        XCTAssertEqual(json["status"]?.stringValue, "partial")
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].objectValue?["domainStatuses"]?.objectValue?["activity"]?.stringValue, "unknown")
        XCTAssertEqual(days[1].objectValue?["domainStatuses"]?.objectValue?["activity"]?.stringValue, "partial")
        XCTAssertTrue(days.allSatisfy { $0.objectValue?["observations"]?.objectValue?.isEmpty == true })
        XCTAssertFalse(result.contains("noData"))
        XCTAssertFalse(result.contains("9876543"))
        XCTAssertFalse(result.contains("sleep"))
        XCTAssertTrue(result.contains("覆盖状态未知或不完整"))
    }

    func testRestrictedEarlierHealthTurnIsRemovedFromProviderHistory() {
        let policy = CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [.healthActivity])
        let messages = [
            ModelMessage(role: .user, text: "请分析我最近的睡眠和活动状态"),
            ModelMessage(role: .assistant, text: "睡眠时长为 999 分钟"),
            ModelMessage(role: .user, text: "下一件事"),
        ]

        let filtered = CloudRequestPolicyGuard.filterConversationHistory(
            messages,
            currentTurnStartIndex: 2,
            by: policy
        )
        let text = filtered.flatMap(\.content).compactMap { content -> String? in
            if case .text(let value) = content { return value }
            return nil
        }.joined()

        XCTAssertFalse(text.contains("999"))
        XCTAssertTrue(text.contains("下一件事"))
    }

    private func makeContext() -> HealthNarrativeContext {
        let window = HealthContextWindowSummary(
            windowDays: 7,
            coverageDays: [
                "sleep": 6,
                "steps": 7,
                "energyIntake": 5,
                "dailyDeficitKcal": 4,
                "bodyMass": 3,
                "sleepAndActivity": 2,
            ],
            averageSleepMinutes: 420,
            averageStepCount: 8_000,
            averageActiveEnergyKcal: 500,
            averageEnergyIntakeKcal: 1_900,
            averageDailyDeficitKcal: 250,
            averageProteinGrams: 90,
            medianWeightKilograms: 60
        )
        let summary = HealthContextSummary(
            sevenDay: window,
            twentyEightDay: window,
            targetWeightKilograms: 58,
            dailyDeficitGoalKcal: 300,
            dailyProteinGoalGrams: 100,
            recommendationReferences: ["sleep.consistency", "activity.gentle-adjustment", "nutrition.review-balance"]
        )
        let baseline = HealthBaseline(
            readiness: .mature,
            validDays: 28,
            median: 400,
            p10: 350,
            p90: 460,
            mad: 20
        )
        let state = HealthStateV2(
            domains: [
                HealthDomainResult(
                    domain: .sleep,
                    status: .attention,
                    currentValue: 420,
                    baseline: baseline,
                    evidenceKeys: ["sleep.latest"]
                ),
                HealthDomainResult(
                    domain: .activity,
                    status: .withinTypicalRange,
                    currentValue: 8_000,
                    baseline: baseline,
                    evidenceKeys: ["activity.steps"]
                ),
            ],
            recovery: RecoveryAssessment(
                status: .attention,
                confidence: .high,
                evidence: [EvidenceReference(key: "sleep.latest", source: "sleep")],
                recommendedAction: .reduceIntensity
            ),
            trainingLoad: TrainingLoadSummary(
                recentSevenDayLoad: 123,
                priorTwentyEightDayAverage: 100,
                ratio: 1.23,
                readiness: .mature,
                band: .nearTypical,
                estimatedWorkoutCount: 3,
                unavailableEffortCount: 0
            ),
            tomorrowGuidance: NextDayGuidance(
                expectedState: .caution,
                confidence: .high,
                reasons: [EvidenceReference(key: "sleep.latest", source: "sleep")],
                recommendedAction: .reduceIntensity,
                conditionalNote: "sleep derived recommendation"
            )
        )
        return HealthNarrativeContext(
            healthState: state,
            evidence: [
                EvidenceReference(key: "sleep.latest", source: "sleep"),
                EvidenceReference(key: "activity.steps", source: "activity"),
            ],
            recommendationCandidates: [],
            aggregateSummary: summary
        )
    }
}

private actor RevokesSleepConsentDuringSnapshotRepository: ProviderGovernanceRepository {
    private var granted = Set(CloudHealthContextPolicy.dataClasses)
    private var didRevokeSleep = false

    func isConsentGranted(provider: ProviderID, dataClass: ProviderDataClass) -> Bool {
        guard provider == .deepSeek else { return false }
        let wasGranted = granted.contains(dataClass)
        if dataClass == .healthSleep && !didRevokeSleep {
            didRevokeSleep = true
            granted.remove(.healthSleep)
        }
        return wasGranted
    }

    func setConsent(
        provider: ProviderID,
        dataClass: ProviderDataClass,
        granted: Bool,
        policyVersion: String
    ) {
        guard provider == .deepSeek else { return }
        if granted { self.granted.insert(dataClass) } else { self.granted.remove(dataClass) }
    }

    func recordUsage(
        usage: ProviderUsage,
        usageKey: String,
        requestID: UUID,
        estimatedCostMicros: Int64?,
        currency: String?,
        rateVersion: String
    ) -> Bool {
        false
    }

    func monthlyUsage(
        provider: ProviderID,
        monthStart: Date,
        monthEnd: Date
    ) -> ProviderUsageSummary {
        ProviderUsageSummary(
            provider: provider,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            imageCount: 0,
            audioSeconds: 0,
            averageLatencyMilliseconds: nil,
            estimatedCostMicros: nil,
            currency: nil
        )
    }
}
