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

    func testPendingExpansionConfirmationCannotRestoreSettingsRevocation() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let draft = try await CloudHealthContextPolicy.stageConversationExpansion(
            provider: .deepSeek,
            requestedClasses: [.healthSleep, .healthActivity],
            repository: repository
        )
        let revoked = try await CloudHealthContextPolicy.applyRestrictiveChange(
            provider: .deepSeek,
            allowedClasses: [],
            repository: repository,
            changeSource: .settings
        )
        let consentRevisionsBeforeStaleConfirmation = try await repository.currentSendConsentRevisions(provider: .deepSeek)

        do {
            _ = try await repository.confirmCloudHealthContextPolicyDraft(
                expectedPolicyID: draft.policyID,
                expectedRevision: draft.revision,
                expectedState: .draft,
                expectedAllowedClasses: draft.allowedClasses,
                provider: .deepSeek,
                confirmedAt: Date(),
                changeSource: .agentConversation
            )
            XCTFail("A stale draft must not restore a policy revoked in Settings")
        } catch {
            XCTAssertEqual(error as? CloudHealthContextPolicyError, .noPendingExpansion)
        }

        let persisted = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        let consentRevisionsAfterStaleConfirmation = try await repository.currentSendConsentRevisions(provider: .deepSeek)
        let sleepConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthSleep)
        let activityConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthActivity)
        XCTAssertEqual(persisted, revoked)
        XCTAssertEqual(consentRevisionsAfterStaleConfirmation, consentRevisionsBeforeStaleConfirmation)
        XCTAssertFalse(sleepConsent)
        XCTAssertFalse(activityConsent)
    }

    func testPendingExpansionConfirmationUsesAtomicDraftTransition() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let draft = try await CloudHealthContextPolicy.stageConversationExpansion(
            provider: .deepSeek,
            requestedClasses: [.healthSleep, .healthNutrition],
            repository: repository
        )
        let confirmedAt = Date(timeIntervalSince1970: 1_798_000_200)

        let confirmed = try await CloudHealthContextPolicy.confirmPendingConversationExpansion(
            provider: .deepSeek,
            repository: repository,
            confirmedAt: confirmedAt
        )

        let sleepConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthSleep)
        let nutritionConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthNutrition)
        XCTAssertEqual(confirmed.policyID, draft.policyID)
        XCTAssertEqual(confirmed.revision, draft.revision + 1)
        XCTAssertEqual(confirmed.state, .active)
        XCTAssertEqual(confirmed.allowedClasses, [.healthSleep, .healthNutrition])
        XCTAssertEqual(confirmed.confirmedAt, confirmedAt)
        XCTAssertTrue(sleepConsent)
        XCTAssertTrue(nutritionConsent)
    }

    func testPendingExpansionKeepsPreviouslyConfirmedClassesAvailable() async throws {
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
            confirmedAt: Date()
        )
        _ = try await CloudHealthContextPolicy.stageConversationExpansion(
            provider: .deepSeek,
            requestedClasses: [.healthActivity],
            repository: repository
        )

        let pendingPolicy = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)
        XCTAssertEqual(pendingPolicy.snapshot.state, .draft)
        XCTAssertEqual(pendingPolicy.allowedClasses, [.healthSleep])
        XCTAssertTrue(pendingPolicy.allows(.healthSleep))
        XCTAssertFalse(pendingPolicy.allows(.healthActivity))
    }

    func testPendingExpansionConfirmationCannotRestoreUserCanceledDraft() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let draft = try await CloudHealthContextPolicy.stageConversationExpansion(
            provider: .deepSeek,
            requestedClasses: [.healthNutrition],
            repository: repository
        )
        let cancelled = try await CloudHealthContextPolicy.cancelPendingConversationExpansion(
            provider: .deepSeek,
            repository: repository
        )

        do {
            _ = try await repository.confirmCloudHealthContextPolicyDraft(
                expectedPolicyID: draft.policyID,
                expectedRevision: draft.revision,
                expectedState: .draft,
                expectedAllowedClasses: draft.allowedClasses,
                provider: .deepSeek,
                confirmedAt: Date(),
                changeSource: .agentConversation
            )
            XCTFail("A canceled expansion draft must not grant consent")
        } catch {
            XCTAssertEqual(error as? CloudHealthContextPolicyError, .noPendingExpansion)
        }

        let persisted = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        let nutritionConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthNutrition)
        XCTAssertEqual(persisted, cancelled)
        XCTAssertFalse(nutritionConsent)
    }

    func testConcurrentConfirmationsOfOneDraftCommitOnlyOnce() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let draft = try await CloudHealthContextPolicy.stageConversationExpansion(
            provider: .deepSeek,
            requestedClasses: [.healthSleep],
            repository: repository
        )

        let first = Task {
            do {
                _ = try await repository.confirmCloudHealthContextPolicyDraft(
                    expectedPolicyID: draft.policyID,
                    expectedRevision: draft.revision,
                    expectedState: .draft,
                    expectedAllowedClasses: draft.allowedClasses,
                    provider: .deepSeek,
                    confirmedAt: Date(timeIntervalSince1970: 1_798_000_100),
                    changeSource: .agentConversation
                )
                return true
            } catch {
                return false
            }
        }
        let second = Task {
            do {
                _ = try await repository.confirmCloudHealthContextPolicyDraft(
                    expectedPolicyID: draft.policyID,
                    expectedRevision: draft.revision,
                    expectedState: .draft,
                    expectedAllowedClasses: draft.allowedClasses,
                    provider: .deepSeek,
                    confirmedAt: Date(timeIntervalSince1970: 1_798_000_101),
                    changeSource: .agentConversation
                )
                return true
            } catch {
                return false
            }
        }

        let firstSucceeded = await first.value
        let secondSucceeded = await second.value
        let persisted = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        let sleepConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthSleep)
        XCTAssertNotEqual(firstSucceeded, secondSucceeded)
        XCTAssertEqual(persisted.state, .active)
        XCTAssertEqual(persisted.allowedClasses, [.healthSleep])
        XCTAssertEqual(persisted.revision, draft.revision + 1)
        XCTAssertTrue(sleepConsent)
    }

    func testConcurrentSettingsRevocationCannotBeReversedByDraftConfirmation() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let draft = try await CloudHealthContextPolicy.stageConversationExpansion(
            provider: .deepSeek,
            requestedClasses: [.healthSleep],
            repository: repository
        )

        let confirmation = Task {
            _ = try? await repository.confirmCloudHealthContextPolicyDraft(
                expectedPolicyID: draft.policyID,
                expectedRevision: draft.revision,
                expectedState: .draft,
                expectedAllowedClasses: draft.allowedClasses,
                provider: .deepSeek,
                confirmedAt: Date(),
                changeSource: .agentConversation
            )
        }
        async let revocation = CloudHealthContextPolicy.applyRestrictiveChange(
            provider: .deepSeek,
            allowedClasses: [],
            repository: repository,
            changeSource: .settings
        )
        await confirmation.value
        _ = try await revocation

        let persisted = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        let sleepConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthSleep)
        XCTAssertEqual(persisted.state, .revoked)
        XCTAssertTrue(persisted.allowedClasses.isEmpty)
        XCTAssertGreaterThan(persisted.revision, draft.revision)
        XCTAssertFalse(sleepConsent)
    }

    func testStaleSettingsExpansionCannotRestorePreviouslyRevokedHealthClass() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthSleep, .healthActivity],
            repository: repository,
            confirmedAt: Date()
        )
        let staleSnapshot = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        let revoked = try await CloudHealthContextPolicy.applyRestrictiveChange(
            provider: .deepSeek,
            allowedClasses: [.healthActivity],
            repository: repository,
            changeSource: .settings
        )

        do {
            _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
                provider: .deepSeek,
                allowedClasses: [.healthSleep, .healthActivity, .healthBody],
                repository: repository,
                expectedSnapshot: staleSnapshot,
                confirmedAt: Date(),
                changeSource: .settings
            )
            XCTFail("A confirmation based on a stale Settings snapshot must not restore Sleep")
        } catch {
            XCTAssertEqual(error as? CloudHealthContextPolicyError, .stalePolicyRevision)
        }

        let persisted = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        let sleepConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthSleep)
        let bodyConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthBody)
        let activityConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthActivity)
        XCTAssertEqual(persisted, revoked)
        XCTAssertFalse(sleepConsent)
        XCTAssertFalse(bodyConsent)
        XCTAssertTrue(activityConsent)
    }

    func testStaleConversationHistoryConfirmationCannotOverrideRevocation() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .qwen,
            allowedClasses: [.healthActivity],
            repository: repository,
            confirmedAt: Date()
        )
        _ = try await CloudHealthContextPolicy.updateConversationHistoryConsent(
            provider: .qwen,
            allowed: true,
            repository: repository,
            confirmedAt: Date()
        )
        let staleSnapshot = try await repository.currentCloudHealthContextPolicySnapshot(provider: .qwen)
        let revoked = try await CloudHealthContextPolicy.updateConversationHistoryConsent(
            provider: .qwen,
            allowed: false,
            repository: repository,
            changeSource: .settings
        )

        do {
            _ = try await CloudHealthContextPolicy.updateConversationHistoryConsent(
                provider: .qwen,
                allowed: true,
                repository: repository,
                expectedSnapshot: staleSnapshot,
                confirmedAt: Date(),
                changeSource: .settings
            )
            XCTFail("A stale history confirmation must not restore revoked conversation history")
        } catch {
            XCTAssertEqual(error as? CloudHealthContextPolicyError, .stalePolicyRevision)
        }

        let persisted = try await repository.currentCloudHealthContextPolicySnapshot(provider: .qwen)
        let historyConsent = try await repository.isConsentGranted(provider: .qwen, dataClass: .conversationHistory)
        let activityConsent = try await repository.isConsentGranted(provider: .qwen, dataClass: .healthActivity)
        XCTAssertEqual(persisted, revoked)
        XCTAssertFalse(historyConsent)
        XCTAssertTrue(activityConsent)
    }

    func testStaleExpansionStageCannotRebuildFromAnOlderPolicySnapshot() async throws {
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
            confirmedAt: Date()
        )
        let staleSnapshot = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        let revoked = try await CloudHealthContextPolicy.applyRestrictiveChange(
            provider: .deepSeek,
            allowedClasses: [.healthActivity],
            repository: repository,
            changeSource: .settings
        )

        do {
            _ = try await repository.stageCloudHealthContextPolicyDraft(
                expectedSnapshot: staleSnapshot,
                provider: .deepSeek,
                allowedClasses: [.healthActivity, .healthSleep, .healthBody],
                changeSource: .settings
            )
            XCTFail("A stale expansion stage must not carry a revoked class into a new draft")
        } catch {
            XCTAssertEqual(error as? CloudHealthContextPolicyError, .stalePolicyRevision)
        }

        let persisted = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        let sleepConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthSleep)
        XCTAssertEqual(persisted, revoked)
        XCTAssertFalse(sleepConsent)
    }

    func testOlderDraftRevisionCannotConfirmNewerDraft() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let oldDraft = try await CloudHealthContextPolicy.stageConversationExpansion(
            provider: .deepSeek,
            requestedClasses: [.healthSleep],
            repository: repository
        )
        let currentDraft = try await CloudHealthContextPolicy.stageConversationExpansion(
            provider: .deepSeek,
            requestedClasses: [.healthSleep, .healthActivity],
            repository: repository
        )

        do {
            _ = try await repository.confirmCloudHealthContextPolicyDraft(
                expectedPolicyID: oldDraft.policyID,
                expectedRevision: oldDraft.revision,
                expectedState: .draft,
                expectedAllowedClasses: oldDraft.allowedClasses,
                provider: .deepSeek,
                confirmedAt: Date(),
                changeSource: .agentConversation
            )
            XCTFail("An older draft revision must not confirm the current draft")
        } catch {
            XCTAssertEqual(error as? CloudHealthContextPolicyError, .noPendingExpansion)
        }

        let persisted = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        let sleepConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthSleep)
        let activityConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthActivity)
        XCTAssertEqual(persisted, currentDraft)
        XCTAssertEqual(persisted.state, .draft)
        XCTAssertFalse(sleepConsent)
        XCTAssertFalse(activityConsent)
    }

    func testFailedDraftSaveRollsBackPolicyAndCanNeitherConfirmNorCancel() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let before = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        let consentRevisionsBefore = try await repository.currentSendConsentRevisions(provider: .deepSeek)
        await repository.failNextPolicySnapshotSaveForTesting()

        do {
            _ = try await CloudHealthContextPolicy.stageConversationExpansion(
                provider: .deepSeek,
                requestedClasses: [.healthNutrition],
                repository: repository
            )
            XCTFail("Draft staging must fail when persistence fails")
        } catch {
            XCTAssertFalse(error is CloudHealthContextPolicyError)
        }

        let afterFailure = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        let consentRevisionsAfter = try await repository.currentSendConsentRevisions(provider: .deepSeek)
        XCTAssertEqual(afterFailure, before)
        XCTAssertEqual(consentRevisionsAfter, consentRevisionsBefore)

        do {
            _ = try await CloudHealthContextPolicy.confirmPendingConversationExpansion(
                provider: .deepSeek,
                repository: repository
            )
            XCTFail("An unpersisted draft must not be confirmable")
        } catch {
            XCTAssertEqual(error as? CloudHealthContextPolicyError, .noPendingExpansion)
        }
        do {
            _ = try await CloudHealthContextPolicy.cancelPendingConversationExpansion(
                provider: .deepSeek,
                repository: repository
            )
            XCTFail("An unpersisted draft must not be cancelable")
        } catch {
            XCTAssertEqual(error as? CloudHealthContextPolicyError, .noPendingExpansion)
        }
        let persistedAfterConfirmationAndCancellation = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        XCTAssertEqual(persistedAfterConfirmationAndCancellation, before)
    }

    func testFailedConfirmationSaveRollsBackAllConsentChangesAndAllowsRetry() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)
        let draft = try await CloudHealthContextPolicy.stageConversationExpansion(
            provider: .deepSeek,
            requestedClasses: [.healthSleep, .healthNutrition],
            repository: repository
        )
        let revisionsBefore = try await repository.currentSendConsentRevisions(provider: .deepSeek)
        var consentStatesBefore: [ProviderDataClass: Bool] = [:]
        for dataClass in ProviderDataClass.allCases {
            consentStatesBefore[dataClass] = try await repository.isConsentGranted(
                provider: .deepSeek,
                dataClass: dataClass
            )
        }
        await repository.failNextPolicySnapshotSaveForTesting()

        do {
            _ = try await CloudHealthContextPolicy.confirmPendingConversationExpansion(
                provider: .deepSeek,
                repository: repository
            )
            XCTFail("Confirmation must fail when its persistence transaction fails")
        } catch {
            XCTAssertFalse(error is CloudHealthContextPolicyError)
        }

        let afterFailure = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        let revisionsAfter = try await repository.currentSendConsentRevisions(provider: .deepSeek)
        var consentStatesAfter: [ProviderDataClass: Bool] = [:]
        for dataClass in ProviderDataClass.allCases {
            consentStatesAfter[dataClass] = try await repository.isConsentGranted(
                provider: .deepSeek,
                dataClass: dataClass
            )
        }
        XCTAssertEqual(afterFailure, draft)
        XCTAssertEqual(revisionsAfter, revisionsBefore)
        XCTAssertEqual(consentStatesAfter, consentStatesBefore)

        let confirmed = try await CloudHealthContextPolicy.confirmPendingConversationExpansion(
            provider: .deepSeek,
            repository: repository
        )
        XCTAssertEqual(confirmed.policyID, draft.policyID)
        XCTAssertEqual(confirmed.revision, draft.revision + 1)
        XCTAssertEqual(confirmed.state, .active)
        XCTAssertEqual(confirmed.allowedClasses, [.healthSleep, .healthNutrition])
        let sleepConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthSleep)
        let nutritionConsent = try await repository.isConsentGranted(provider: .deepSeek, dataClass: .healthNutrition)
        XCTAssertTrue(sleepConsent)
        XCTAssertTrue(nutritionConsent)
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

    func testImageConsentReconfirmationDoesNotAdvanceHealthPolicyRevision() async throws {
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

        XCTAssertEqual(firstGrant.revision, initial.revision)
        XCTAssertEqual(reconfirmed.revision, initial.revision)
        XCTAssertEqual(reconfirmed.allowedClasses, initial.allowedClasses)
    }

    func testImageConsentReconfirmationAdvancesTheFinalSendPolicyRevision() async throws {
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
        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .mealImage,
            granted: true,
            policyVersion: "deepseek-sanitized-meal-image-v1"
        )
        let expectedSendPolicy = try await CloudHealthContextPolicy.load(
            from: repository,
            provider: .deepSeek
        )

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

        let currentSendPolicy = try await CloudHealthContextPolicy.load(
            from: repository,
            provider: .deepSeek
        )
        XCTAssertEqual(currentSendPolicy.snapshot.revision, expectedSendPolicy.snapshot.revision)
        XCTAssertNotEqual(
            currentSendPolicy.sendConsentRevisions[.mealImage],
            expectedSendPolicy.sendConsentRevisions[.mealImage]
        )

        do {
            _ = try await CloudHealthContextPolicy.withCurrentSendConsent(
                from: repository,
                provider: .deepSeek,
                expectedHealthPolicy: expectedSendPolicy,
                includesImage: true,
                operation: { true }
            )
            XCTFail("A previously captured image request must be rejected after consent revocation and reconfirmation")
        } catch {
            XCTAssertEqual(error as? ProviderError, .consentPolicyChanged(provider: .deepSeek))
        }
    }

    func testRepeatedHealthDenialDoesNotAdvancePolicyRevisionOrInvalidateRequest() async throws {
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
        let expectedSnapshot = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthSleep],
            repository: repository,
            changeSource: .settings
        )
        let expectedPolicy = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)

        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .healthActivity,
            granted: false,
            policyVersion: "cloud-health-context-v1"
        )
        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .healthActivity,
            granted: false,
            policyVersion: "cloud-health-context-v1"
        )

        let currentSnapshot = try await repository.currentCloudHealthContextPolicySnapshot(
            provider: .deepSeek
        )
        XCTAssertEqual(currentSnapshot, expectedSnapshot)
        let authorized = try await CloudHealthContextPolicy.withCurrentSendConsent(
            from: repository,
            provider: .deepSeek,
            expectedHealthPolicy: expectedPolicy,
            includesImage: false
        ) { "text-body" }
        XCTAssertEqual(authorized, "text-body")
    }

    func testSpeechConsentChangeDoesNotInvalidateTextHealthRequest() async throws {
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
        _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthSleep],
            repository: repository,
            changeSource: .settings
        )
        let expected = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)

        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .speechAudio,
            granted: true,
            policyVersion: "speech-audio-v1"
        )

        let authorized = try await CloudHealthContextPolicy.withCurrentSendConsent(
            from: repository,
            provider: .deepSeek,
            expectedHealthPolicy: expected,
            includesImage: false
        ) { "text-body" }
        XCTAssertEqual(authorized, "text-body")
        let currentPolicy = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        XCTAssertEqual(currentPolicy, expected.snapshot)
    }

    func testMealImageConsentChangeDoesNotInvalidateUnrelatedTextRequest() async throws {
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
        _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthActivity],
            repository: repository,
            changeSource: .settings
        )
        let expected = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)

        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .mealImage,
            granted: true,
            policyVersion: "meal-image-v1"
        )
        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .mealImage,
            granted: false,
            policyVersion: "meal-image-v1"
        )

        let authorized = try await CloudHealthContextPolicy.withCurrentSendConsent(
            from: repository,
            provider: .deepSeek,
            expectedHealthPolicy: expected,
            includesImage: false
        ) { "text-body" }
        XCTAssertEqual(authorized, "text-body")
        let currentPolicy = try await repository.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        XCTAssertEqual(currentPolicy, expected.snapshot)
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
        XCTAssertNil(filtered?.healthState)
        XCTAssertNil(filtered?.cloudHealthState?.recovery)
        XCTAssertNil(filtered?.cloudHealthState?.tomorrowGuidance)
        XCTAssertEqual(filtered?.cloudHealthState?.trainingLoad?.band, .nearTypical)

        let sleepOnlyPolicy = CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [.healthSleep])
        let sleepOnly = CloudRequestPolicyGuard.filtered(makeContext(), by: sleepOnlyPolicy)
        XCTAssertNil(sleepOnly?.healthState)
        XCTAssertEqual(sleepOnly?.cloudHealthState?.domains.map(\.domain), [.sleep])
        XCTAssertNil(sleepOnly?.cloudHealthState?.trainingLoad)
        XCTAssertNil(sleepOnly?.aggregateSummary?.sevenDay.averageStepCount)
        XCTAssertNil(sleepOnly?.aggregateSummary?.sevenDay.averageActiveEnergyKcal)
        XCTAssertNil(sleepOnly?.aggregateSummary?.sevenDay.averageEnergyIntakeKcal)
        XCTAssertEqual(
            Set(sleepOnly?.aggregateSummary?.sevenDay.coverageDays.keys.map { $0 } ?? []),
            Set(["sleep"])
        )
    }

    func testNarrativeHealthStateUsesIndependentSleepNutritionBodyAndActivityConsent() throws {
        let baseline = HealthBaseline(
            readiness: .mature,
            validDays: 28,
            median: 420,
            p10: 380,
            p90: 460,
            mad: 20
        )
        let domains = HealthDomain.allCases.map { domain in
            HealthDomainResult(
                domain: domain,
                status: .withinTypicalRange,
                currentValue: Double(domain.rawValue.count * 100),
                baseline: baseline,
                evidenceKeys: ["\(domain.rawValue).current"]
            )
        }
        let state = HealthStateV2(
            domains: domains,
            recovery: RecoveryAssessment(
                status: .attention,
                confidence: .medium,
                evidence: [
                    EvidenceReference(key: "sleep.current", source: "sleep"),
                    EvidenceReference(key: "activity.current", source: "activity"),
                    EvidenceReference(key: "body.current", source: "body"),
                ],
            recommendedAction: .reduceIntensity,
            missingEvidenceKeys: ["vitals.heartRateVariability.median"]
            ),
            trainingLoad: TrainingLoadSummary(
                recentSevenDayLoad: 120,
                priorTwentyEightDayAverage: 100,
                ratio: 1.2,
                readiness: .mature,
                band: .increased,
                estimatedWorkoutCount: 3,
                unavailableEffortCount: 0
            ),
            tomorrowGuidance: nil
        )
        let baselineTrend = HealthBaseline(
            readiness: .mature,
            validDays: 28,
            median: 61,
            p10: 58,
            p90: 64,
            mad: 2
        )
        let trends = [
            HealthVitalTrend(
                metric: .restingHeartRate,
                latestMedian: 66,
                currentSampleCount: 2,
                baseline: baselineTrend,
                status: .changed,
                evidenceKey: "vitals.restingHeartRate.median"
            ),
            HealthVitalTrend(
                metric: .bodyWeight,
                latestMedian: nil,
                baseline: baselineTrend,
                status: .noData,
                evidenceKey: "vitals.bodyWeight.median"
            ),
        ]
        let context = HealthNarrativeContext(
            healthState: state,
            evidence: [
                EvidenceReference(key: "sleep.current", source: "sleep"),
                EvidenceReference(key: "nutrition.current", source: "nutrition"),
                EvidenceReference(key: "activity.current", source: "activity"),
                EvidenceReference(key: "body.current", source: "body"),
                EvidenceReference(key: "vitals.restingHeartRate.median", source: "restingHeartRate"),
                EvidenceReference(key: "vitals.bodyWeight.median", source: "bodyWeight"),
                EvidenceReference(key: "sleep.private", source: "body"),
                EvidenceReference(key: "body.private", source: "sleep"),
            ],
            recommendationCandidates: [],
            aggregateSummary: nil,
            vitalTrends: trends
        )

        func filtered(_ dataClass: ProviderDataClass) -> HealthNarrativeContext? {
            CloudRequestPolicyGuard.filtered(
                context,
                by: CloudHealthContextPolicy(provider: .qwen, allowedClasses: [dataClass])
            )
        }

        let sleepOnly = try XCTUnwrap(filtered(.healthSleep))
        XCTAssertNil(sleepOnly.healthState)
        XCTAssertEqual(sleepOnly.cloudHealthState?.domains.map(\.domain), [.sleep])
        XCTAssertNil(sleepOnly.cloudHealthState?.trainingLoad)
        XCTAssertNil(sleepOnly.cloudHealthState?.recovery)
        XCTAssertTrue(sleepOnly.vitalTrends.isEmpty)

        let nutritionOnly = try XCTUnwrap(filtered(.healthNutrition))
        XCTAssertEqual(nutritionOnly.cloudHealthState?.domains.map(\.domain), [.nutrition])
        XCTAssertNil(nutritionOnly.cloudHealthState?.trainingLoad)
        XCTAssertTrue(nutritionOnly.vitalTrends.isEmpty)

        let bodyOnly = try XCTUnwrap(filtered(.healthBody))
        XCTAssertEqual(bodyOnly.cloudHealthState?.domains.map(\.domain), [.body])
        XCTAssertNil(bodyOnly.cloudHealthState?.trainingLoad)
        XCTAssertNil(bodyOnly.cloudHealthState?.recovery)
        XCTAssertEqual(bodyOnly.vitalTrends.map(\.metric), [.restingHeartRate, .bodyWeight])
        XCTAssertEqual(
            bodyOnly.evidence.map(\.key),
            ["body.current", "vitals.restingHeartRate.median"]
        )
        let encodedBodyContext = try JSONEncoder().encode(bodyOnly)
        let encodedBodyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedBodyContext) as? [String: Any]
        )
        let encodedBodyTrends = try XCTUnwrap(encodedBodyObject["vitalTrends"] as? [[String: Any]])
        XCTAssertEqual(encodedBodyTrends[0]["evidenceKey"] as? String, "vitals.restingHeartRate.median")
        XCTAssertEqual(encodedBodyTrends[0]["currentSampleCount"] as? Int, 2)
        XCTAssertNil(encodedBodyTrends[1]["evidenceKey"])
        XCTAssertEqual(
            encodedBodyTrends[1]["sourceProvenance"] as? String,
            HealthVitalAggregateProvenance.localOrHealthKitAggregate.rawValue
        )

        let activityOnly = try XCTUnwrap(filtered(.healthActivity))
        XCTAssertEqual(activityOnly.cloudHealthState?.domains.map(\.domain), [.activity])
        XCTAssertEqual(activityOnly.cloudHealthState?.trainingLoad?.band, .increased)
        let activityDomain = try XCTUnwrap(activityOnly.cloudHealthState?.domains.first)
        XCTAssertEqual(activityDomain.dataCoverage, .unknown)
        XCTAssertEqual(activityDomain.status, .unknown)
        XCTAssertNil(activityDomain.currentValue)
        XCTAssertTrue(activityDomain.evidenceKeys.isEmpty)
        XCTAssertNil(activityOnly.cloudHealthState?.recovery)
        XCTAssertTrue(activityOnly.vitalTrends.isEmpty)

        let allAuthorized = try XCTUnwrap(CloudRequestPolicyGuard.filtered(
            context,
            by: CloudHealthContextPolicy(
                provider: .qwen,
                allowedClasses: [.healthSleep, .healthActivity, .healthBody]
            )
        ))
        XCTAssertEqual(
            allAuthorized.cloudHealthState?.recovery?.missingEvidenceKeys,
            ["vitals.heartRateVariability.median"]
        )
    }

    func testNutritionOnlyConsentKeepsRecommendationsThatOnlyUseNutritionEvidence() throws {
        let nutritionOnly = HealthRecommendation(
            id: "nutrition.review-balance",
            domain: .nutrition,
            title: "回看今天的饮食节奏",
            detail: "可以回看餐食份量与记录完整度。",
            evidenceKey: "nutrition.energyIntake.kcal",
            conflictGroup: "nutrition-balance",
            score: 0.65,
            requiredDataDomains: [.nutrition]
        )
        let deficitRecommendation = HealthRecommendation(
            id: "nutrition.deficit-aware",
            domain: .nutrition,
            title: "查看能量目标",
            detail: "结合活动与摄入查看目标。",
            evidenceKey: "nutrition.energyIntake.kcal",
            conflictGroup: "nutrition-deficit",
            score: 0.6,
            requiredDataDomains: [.nutrition, .activity]
        )
        let context = HealthNarrativeContext(
            healthState: nil,
            evidence: [EvidenceReference(key: "nutrition.energyIntake.kcal", source: "nutrition")],
            recommendationCandidates: [nutritionOnly, deficitRecommendation],
            aggregateSummary: nil
        )

        let filtered = try XCTUnwrap(CloudRequestPolicyGuard.filtered(
            context,
            by: CloudHealthContextPolicy(provider: .qwen, allowedClasses: [.healthNutrition])
        ))
        XCTAssertEqual(filtered.recommendationCandidates.map(\.id), ["nutrition.review-balance"])
    }

    func testStructuredActivityTrendsRequireActivityConsentAndKnownMetricEvidence() throws {
        let baseline = HealthBaseline(
            readiness: .mature,
            validDays: 14,
            median: 7_200,
            p10: 5_000,
            p90: 9_000,
            mad: 600
        )
        let context = HealthNarrativeContext(
            healthState: nil,
            evidence: [
                EvidenceReference(key: "activity.steps", source: HealthDomain.activity.rawValue),
                EvidenceReference(key: "activity.activeEnergy.kcal", source: HealthDomain.activity.rawValue),
                EvidenceReference(key: "activity.forged", source: HealthDomain.activity.rawValue),
            ],
            recommendationCandidates: [HealthRecommendation(
                id: "activity.unknown",
                domain: .activity,
                title: "未知指标",
                detail: "不应进入云端证据列表。",
                evidenceKey: "activity.activeEnergy.kcal",
                conflictGroup: "activity",
                score: 0.5
            )],
            aggregateSummary: nil,
            activityTrends: [
                ActivityMetricTrend(
                    metric: .steps,
                    currentValue: 8_300,
                    baselineWindowDays: 28,
                    baseline: baseline,
                    status: .withinTypicalRange,
                    dataCoverage: .complete
                ),
                ActivityMetricTrend(
                    metric: .activeEnergy,
                    currentValue: nil,
                    baselineWindowDays: 28,
                    baseline: baseline,
                    status: .unknown,
                    dataCoverage: .unknown
                ),
            ]
        )

        let activityOnly = try XCTUnwrap(CloudRequestPolicyGuard.filtered(
            context,
            by: CloudHealthContextPolicy(provider: .qwen, allowedClasses: [.healthActivity])
        ))
        XCTAssertEqual(activityOnly.activityTrends.map(\.metric), [.steps, .activeEnergy])
        XCTAssertEqual(activityOnly.evidence.map(\.key), ["activity.steps"])
        XCTAssertEqual(activityOnly.allowedEvidenceKeys, ["activity.steps"])
        XCTAssertTrue(activityOnly.recommendationCandidates.isEmpty)

        let nutritionOnly = CloudRequestPolicyGuard.filtered(
            context,
            by: CloudHealthContextPolicy(provider: .qwen, allowedClasses: [.healthNutrition])
        )
        XCTAssertNil(nutritionOnly)
    }

    func testTodayHealthStateBodyConsentKeepsVitalAggregatesBaselineAndEvidence() throws {
        let baseline = HealthBaseline(
            readiness: .mature,
            validDays: 28,
            median: 61,
            p10: 58,
            p90: 64,
            mad: 2
        )
        let state = HealthStateV2(
            domains: [
                HealthDomainResult(
                    domain: .sleep,
                    status: .attention,
                    currentValue: 400,
                    baseline: baseline,
                    evidenceKeys: ["sleep.private"]
                ),
                HealthDomainResult(
                    domain: .body,
                    status: .changed,
                    currentValue: 66,
                    baseline: baseline,
                    evidenceKeys: ["body.visible"]
                ),
                HealthDomainResult(
                    domain: .activity,
                    status: .attention,
                    currentValue: 12345,
                    baseline: baseline,
                    evidenceKeys: ["activity.private"]
                ),
            ],
            recovery: RecoveryAssessment(
                status: .attention,
                confidence: .high,
                evidence: [EvidenceReference(key: "sleep.private", source: "sleep")],
                recommendedAction: .reduceIntensity
            ),
            trainingLoad: TrainingLoadSummary(
                recentSevenDayLoad: 120,
                priorTwentyEightDayAverage: 100,
                ratio: 1.2,
                readiness: .mature,
                band: .increased,
                estimatedWorkoutCount: 3,
                unavailableEffortCount: 0
            ),
            tomorrowGuidance: nil
        )
        let trend = HealthVitalTrend(
            metric: .restingHeartRate,
            latestMedian: 66,
            currentSampleCount: 2,
            baseline: baseline,
            status: .changed,
            evidenceKey: "vitals.restingHeartRate.median"
        )
        let response = try GetTodayHealthStateTool().response(
            asOf: Date(timeIntervalSince1970: 1_800_000_000),
            context: HealthNarrativeContext(
                healthState: state,
                evidence: [
                    EvidenceReference(key: "sleep.private", source: "sleep"),
                    EvidenceReference(key: "body.visible", source: "body"),
                    EvidenceReference(key: "activity.private", source: "activity"),
                    EvidenceReference(key: trend.evidenceKey, source: trend.metric.rawValue),
                ],
                recommendationCandidates: [],
                aggregateSummary: nil,
                vitalTrends: [trend]
            )
        )
        let call = ToolCall(id: "today-body", name: "get_today_health_state", arguments: .object([:]))
        let messages = [
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(role: .tool, content: [.toolResult(toolCallID: call.id, content: response)]),
        ]
        let policy = CloudHealthContextPolicy(provider: .qwen, allowedClasses: [.healthBody])
        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        guard case .toolResult(_, let result)? = filtered.last?.content.first,
              let data = result.data(using: .utf8),
              let json = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            return XCTFail("Expected body-filtered today state")
        }
        let stateJSON = try XCTUnwrap(json["healthState"]?.objectValue)
        let trends = try XCTUnwrap(json["vitalTrends"]?.arrayValue)
        let trendJSON = try XCTUnwrap(trends.first?.objectValue)

        XCTAssertEqual(json["status"]?.stringValue, "available")
        XCTAssertEqual(stateJSON["domains"]?.arrayValue?.count, 1)
        XCTAssertEqual(stateJSON["domains"]?.arrayValue?.first?.objectValue?["domain"]?.stringValue, "body")
        XCTAssertNil(stateJSON["trainingLoad"])
        XCTAssertNil(stateJSON["recovery"])
        XCTAssertEqual(trendJSON["latestMedian"]?.doubleValue, 66)
        XCTAssertEqual(trendJSON["unit"]?.stringValue, "bpm")
        XCTAssertEqual(trendJSON["currentSampleCount"]?.intValue, 2)
        XCTAssertEqual(trendJSON["baseline"]?.objectValue?["median"]?.doubleValue, 61)
        XCTAssertEqual(trendJSON["baselineWindowDays"]?.intValue, 41)
        XCTAssertEqual(trendJSON["status"]?.stringValue, HealthDomainStatus.changed.rawValue)
        XCTAssertEqual(trendJSON["dataCoverage"]?.stringValue, HealthDataCoverage.complete.rawValue)
        XCTAssertEqual(trendJSON["evidenceKey"]?.stringValue, trend.evidenceKey)
        XCTAssertTrue(result.contains("body.visible"))
        XCTAssertFalse(result.contains("sleep.private"))
        XCTAssertFalse(result.contains("activity.private"))
        XCTAssertFalse(result.contains("12345"))
    }

    func testTodayActivityPolicyRetainsOnlyCanonicalTrendsAndNumericEvidence() throws {
        let payload = #"{"status":"available","asOf":"2026-10-01T00:00:00Z","healthState":{"domains":[{"domain":"activity","status":"attention","currentValue":999999,"baseline":{"readiness":"mature","validDays":28,"median":7000,"p10":5000,"p90":9000,"mad":500},"evidenceKeys":["activity.steps","activity.activeEnergy.kcal"]}]},"activityTrends":[{"metric":"steps","unit":"steps","currentValue":8100,"baselineWindowDays":28,"baseline":{"readiness":"mature","validDays":28,"median":7000,"p10":5000,"p90":9000,"mad":500},"status":"attention","evidenceKey":"activity.steps","dataCoverage":"complete"},{"metric":"activeEnergy","unit":"kcal","currentValue":null,"baselineWindowDays":28,"baseline":{"readiness":"noData","validDays":0},"status":"unknown","evidenceKey":"activity.activeEnergy.kcal","dataCoverage":"unknown"},{"metric":"exerciseMinutes","unit":"kcal","currentValue":40,"baselineWindowDays":28,"baseline":{"readiness":"mature","validDays":14,"median":30,"p10":10,"p90":50,"mad":5},"status":"attention","evidenceKey":"activity.exerciseMinutes","dataCoverage":"complete"},{"metric":"activeEnergy","unit":"kcal","currentValue":-45,"baselineWindowDays":28,"baseline":{"readiness":"mature","validDays":10,"median":300,"p10":200,"p90":400,"mad":50},"status":"attention","evidenceKey":"activity.activeEnergy.kcal","dataCoverage":"complete"}],"evidenceReferences":[{"key":"activity.steps","source":"activity"},{"key":"activity.steps","source":"body"},{"key":"activity.activeEnergy.kcal","source":"activity"},{"key":"activity.forged","source":"activity"}]}"#
        let call = ToolCall(id: "today-activity", name: "get_today_health_state", arguments: .object([:]))
        let messages = [
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(role: .tool, content: [.toolResult(toolCallID: call.id, content: payload)]),
        ]
        let filtered = CloudRequestPolicyGuard.filterToolResults(
            in: messages,
            by: CloudHealthContextPolicy(provider: .qwen, allowedClasses: [.healthActivity])
        )
        guard case .toolResult(_, let result)? = filtered.last?.content.first,
              let data = result.data(using: .utf8),
              let json = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            return XCTFail("Expected Activity-only filtered today state")
        }
        let trends = try XCTUnwrap(json["activityTrends"]?.arrayValue)
        let references = try XCTUnwrap(json["evidenceReferences"]?.arrayValue)
        let state = try XCTUnwrap(json["healthState"]?.objectValue)
        let domain = try XCTUnwrap(state["domains"]?.arrayValue?.first?.objectValue)

        XCTAssertEqual(json["status"]?.stringValue, "partial")
        XCTAssertEqual(trends.count, 2)
        XCTAssertEqual(trends[0].objectValue?["metric"]?.stringValue, "steps")
        XCTAssertEqual(trends[1].objectValue?["dataCoverage"]?.stringValue, HealthDataCoverage.unknown.rawValue)
        XCTAssertNil(trends[1].objectValue?["evidenceKey"])
        XCTAssertEqual(domain["evidenceKeys"]?.arrayValue?.compactMap(\.stringValue), ["activity.steps"])
        XCTAssertEqual(domain["currentValue"]?.doubleValue, 8_100)
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?.objectValue?["source"]?.stringValue, HealthDomain.activity.rawValue)
        XCTAssertFalse(result.contains("999999"))
        XCTAssertFalse(result.contains("activity.forged"))
    }

    func testHealthEvidenceFilteringRejectsAuthorizedSourceWithForbiddenKey() throws {
        let policy = CloudHealthContextPolicy(provider: .qwen, allowedClasses: [.healthBody])
        let payload = #"{"status":"available","asOf":"2026-10-01T00:00:00Z","healthState":{"domains":[{"domain":"body","status":"attention","currentValue":68,"baseline":{"readiness":"mature","validDays":28,"median":60,"p10":55,"p90":65,"mad":2},"evidenceKeys":["body.weight.kg","sleep.private"]}]},"vitalTrends":[{"metric":"restingHeartRate","unit":"bpm","dataCoverage":"complete","currentWindowDays":1,"latestMedian":999,"currentSampleCount":3,"baseline":{"readiness":"mature","validDays":28,"median":60,"p10":55,"p90":65,"mad":2},"baselineWindowDays":41,"robustZScore":100,"status":"attention","evidenceKey":"sleep.private"}],"evidenceReferences":[{"key":"body.weight.kg","source":"body"},{"key":"sleep.private","source":"body"},{"key":"vitals.restingHeartRate.median","source":"sleep"}]}"#
        let call = ToolCall(id: "health-evidence-mismatch", name: "get_today_health_state", arguments: .object([:]))
        let messages = [
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(role: .tool, content: [.toolResult(toolCallID: call.id, content: payload)]),
        ]

        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        guard case .toolResult(_, let result)? = filtered.last?.content.first,
              let data = result.data(using: .utf8),
              let json = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            return XCTFail("Expected body-authorized response with mismatched evidence removed")
        }
        let state = try XCTUnwrap(json["healthState"]?.objectValue)
        let domain = try XCTUnwrap(state["domains"]?.arrayValue?.first?.objectValue)
        let trends = try XCTUnwrap(json["vitalTrends"]?.arrayValue)
        let trend = try XCTUnwrap(trends.first?.objectValue)
        let references = try XCTUnwrap(json["evidenceReferences"]?.arrayValue)

        XCTAssertEqual(domain["evidenceKeys"]?.arrayValue?.compactMap(\.stringValue), ["body.weight.kg"])
        XCTAssertNil(trend["latestMedian"])
        XCTAssertNil(trend["currentSampleCount"])
        XCTAssertNil(trend["robustZScore"])
        XCTAssertNil(trend["evidenceKey"])
        XCTAssertEqual(trend["status"]?.stringValue, HealthDomainStatus.noData.rawValue)
        XCTAssertEqual(references.compactMap { $0.objectValue?["key"]?.stringValue }, ["body.weight.kg"])
        XCTAssertFalse(result.contains("sleep.private"))
        XCTAssertFalse(result.contains("999"))
        XCTAssertFalse(result.contains("100"))
    }

    func testUnknownVitalHasNoValueEvidenceKeyOrAllowedPromptEvidence() throws {
        let baseline = HealthBaseline(
            readiness: .mature,
            validDays: 28,
            median: 61,
            p10: 58,
            p90: 64,
            mad: 2
        )
        let context = HealthNarrativeContext(
            healthState: nil,
            evidence: [EvidenceReference(key: "vitals.restingHeartRate.median", source: "restingHeartRate")],
            recommendationCandidates: [HealthRecommendation(
                id: "body.vital-sentinel",
                domain: .body,
                title: "vital sentinel",
                detail: "must not be supported without a current measurement",
                evidenceKey: "vitals.restingHeartRate.median",
                conflictGroup: "body-vital",
                score: 1
            )],
            aggregateSummary: nil,
            vitalTrends: [HealthVitalTrend(
                metric: .restingHeartRate,
                latestMedian: nil,
                baseline: baseline,
                status: .unknown,
                evidenceKey: "vitals.restingHeartRate.median",
                dataCoverage: .unknown
            )]
        )

        XCTAssertFalse(context.allowedEvidenceKeys.contains("vitals.restingHeartRate.median"))
        let filtered = try XCTUnwrap(CloudRequestPolicyGuard.filtered(
            context,
            by: CloudHealthContextPolicy(provider: .qwen, allowedClasses: [.healthBody])
        ))
        let trend = try XCTUnwrap(filtered.vitalTrends.first)
        XCTAssertNil(trend.latestMedian)
        XCTAssertNil(trend.evidenceKey)
        XCTAssertEqual(trend.dataCoverage, .unknown)
        XCTAssertFalse(filtered.allowedEvidenceKeys.contains("vitals.restingHeartRate.median"))
        XCTAssertTrue(filtered.evidence.isEmpty)
        XCTAssertTrue(filtered.recommendationCandidates.isEmpty)
    }

    func testActivityOnlyHistoryKeepsValidatedTrendsAndDropsCrossDomainKeys() throws {
        let payload = #"{"status":"available","startDate":"2026-10-01","endDate":"2026-10-01","days":[{"date":"2026-10-01","domainStatuses":{"activity":"withinTypicalRange"},"observations":{"activity.steps":8200,"activity.forged":99},"activityTrends":[{"metric":"steps","unit":"steps","currentValue":8200,"baselineWindowDays":28,"baseline":{"readiness":"mature","validDays":21,"median":7000,"p10":5000,"p90":9000,"mad":500},"status":"withinTypicalRange","evidenceKey":"activity.steps","dataCoverage":"complete"},{"metric":"activeEnergy","unit":"kcal","currentValue":null,"baselineWindowDays":28,"baseline":{"readiness":"noData","validDays":0},"status":"unknown","evidenceKey":"activity.activeEnergy.kcal","dataCoverage":"unknown"}],"trainingLoadCoverage":"complete","trainingLoadBand":"stable"}]}"#
        let call = ToolCall(id: "history-activity-only", name: "get_health_history", arguments: .object([:]))
        let messages = [
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(role: .tool, content: [.toolResult(toolCallID: call.id, content: payload)]),
        ]
        let activityFiltered = CloudRequestPolicyGuard.filterToolResults(
            in: messages,
            by: CloudHealthContextPolicy(provider: .qwen, allowedClasses: [.healthActivity])
        )
        guard case .toolResult(_, let activityResult)? = activityFiltered.last?.content.first,
              let activityData = activityResult.data(using: .utf8),
              let activityJSON = try JSONDecoder().decode(JSONValue.self, from: activityData).objectValue,
              let activityDay = activityJSON["days"]?.arrayValue?.first?.objectValue else {
            return XCTFail("Expected Activity-only history day")
        }
        let trends = try XCTUnwrap(activityDay["activityTrends"]?.arrayValue)
        let observations = try XCTUnwrap(activityDay["observations"]?.objectValue)

        XCTAssertEqual(activityJSON["status"]?.stringValue, "partial")
        XCTAssertEqual(trends.count, 2)
        XCTAssertEqual(observations["activity.steps"]?.doubleValue, 8_200)
        XCTAssertNil(observations["activity.forged"])
        XCTAssertEqual(trends[1].objectValue?["dataCoverage"]?.stringValue, HealthDataCoverage.unknown.rawValue)
        XCTAssertFalse(activityResult.contains("activity.forged"))

        let bodyFiltered = CloudRequestPolicyGuard.filterToolResults(
            in: messages,
            by: CloudHealthContextPolicy(provider: .qwen, allowedClasses: [.healthBody])
        )
        guard case .toolResult(_, let bodyResult)? = bodyFiltered.last?.content.first,
              let bodyData = bodyResult.data(using: .utf8),
              let bodyJSON = try JSONDecoder().decode(JSONValue.self, from: bodyData).objectValue else {
            return XCTFail("Expected body-only filtered history")
        }
        XCTAssertEqual(bodyJSON["status"]?.stringValue, "noData")
        XCTAssertTrue(bodyJSON["days"]?.arrayValue?.isEmpty == true)
        XCTAssertFalse(bodyResult.contains("activity.steps"))
    }

    func testHealthHistoryBodyConsentDropsVitalsWithMismatchedEvidenceKey() throws {
        let policy = CloudHealthContextPolicy(provider: .qwen, allowedClasses: [.healthBody])
        let payload = #"{"status":"available","startDate":"2026-10-01","endDate":"2026-10-01","days":[{"date":"2026-10-01","domainStatuses":{"body":"attention"},"observations":{"sleep.private":1234,"vitals.restingHeartRate.median":999},"vitalTrends":[{"metric":"restingHeartRate","unit":"bpm","sourceProvenance":"healthKitAggregate","dataCoverage":"complete","currentWindowDays":1,"latestMedian":999,"currentSampleCount":4,"baseline":{"readiness":"mature","validDays":28,"median":60,"p10":55,"p90":65,"mad":2},"baselineWindowDays":41,"robustZScore":100,"status":"attention","evidenceKey":"sleep.private"}]}]}"#
        let call = ToolCall(id: "history-vital-mismatch", name: "get_health_history", arguments: .object([:]))
        let messages = [
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(role: .tool, content: [.toolResult(toolCallID: call.id, content: payload)]),
        ]

        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        guard case .toolResult(_, let result)? = filtered.last?.content.first,
              let data = result.data(using: .utf8),
              let json = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            return XCTFail("Expected body-only filtered history")
        }
        let day = try XCTUnwrap(json["days"]?.arrayValue?.first?.objectValue)
        let observations = try XCTUnwrap(day["observations"]?.objectValue)
        let trend = try XCTUnwrap(day["vitalTrends"]?.arrayValue?.first?.objectValue)

        XCTAssertEqual(json["status"]?.stringValue, "noData")
        XCTAssertTrue(observations.isEmpty)
        XCTAssertNil(trend["latestMedian"])
        XCTAssertNil(trend["evidenceKey"])
        XCTAssertEqual(trend["status"]?.stringValue, HealthDomainStatus.noData.rawValue)
        XCTAssertFalse(result.contains("sleep.private"))
        XCTAssertFalse(result.contains("1234"))
        XCTAssertFalse(result.contains("999"))
        XCTAssertFalse(result.contains("100"))
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
        let payload = #"{"status":"available","healthState":{"domains":[{"domain":"sleep","currentValue":999,"evidenceKeys":["sleep-secret"]},{"domain":"activity","status":"withinTypicalRange","currentValue":123,"evidenceKeys":["activity.steps"]}],"recovery":{"status":"attention","evidence":[{"key":"sleep-secret","source":"sleep"}]},"trainingLoad":{"recentSevenDayLoad":123,"band":"increased"},"tomorrowGuidance":{"conditionalNote":"sleep-secret"}},"activityTrends":[{"metric":"steps","unit":"steps","currentValue":123,"baselineWindowDays":28,"baseline":{"readiness":"mature","validDays":14,"median":120,"p10":100,"p90":140,"mad":10},"status":"withinTypicalRange","evidenceKey":"activity.steps","dataCoverage":"complete"}],"evidenceReferences":[{"key":"sleep-secret","source":"sleep"},{"key":"activity.steps","source":"activity"}]}"#
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

        XCTAssertTrue(sentContent.contains("activity.steps"))
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

        XCTAssertEqual(json["status"]?.stringValue, "partial")
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.objectValue?["date"]?.stringValue, "2026-10-02")
        XCTAssertEqual(
            days.first?.objectValue?["trainingLoadCoverage"]?.stringValue,
            HealthDataCoverage.unknown.rawValue
        )
        XCTAssertNil(days.first?.objectValue?["trainingLoadBand"])
        XCTAssertFalse(result.contains("sleep"))
        XCTAssertFalse(result.contains("999"))
        XCTAssertTrue(result.contains("覆盖状态未知或不完整"))
    }

    func testHealthHistoryPreservesUnknownAndPartialTrainingLoadCoverageWithoutBands() throws {
        let policy = CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [.healthActivity])
        let payload = #"{"status":"available","startDate":"2026-10-01","endDate":"2026-10-03","days":[{"date":"2026-10-01","domainStatuses":{"activity":"unknown"},"observations":{},"trainingLoadCoverage":"unknown","trainingLoadBand":"unavailable"},{"date":"2026-10-02","domainStatuses":{"activity":"partial"},"observations":{},"trainingLoadCoverage":"partial","trainingLoadBand":"nearTypical"},{"date":"2026-10-03","domainStatuses":{"activity":"attention"},"observations":{"activity.steps":8000},"trainingLoadCoverage":"complete","trainingLoadBand":"nearTypical"}]}"#
        let call = ToolCall(id: "history-training-coverage", name: "get_health_history", arguments: .object([:]))
        let messages = [
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(role: .tool, content: [.toolResult(toolCallID: call.id, content: payload)]),
        ]

        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        guard case .toolResult(_, let result)? = filtered.last?.content.first,
              let data = result.data(using: .utf8),
              let json = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            return XCTFail("Expected activity history with preserved load coverage")
        }
        let days = try XCTUnwrap(json["days"]?.arrayValue)
        XCTAssertEqual(json["status"]?.stringValue, "partial")
        XCTAssertEqual(days.map { $0.objectValue?["trainingLoadCoverage"]?.stringValue }, ["unknown", "partial", "complete"])
        XCTAssertNil(days[0].objectValue?["trainingLoadBand"])
        XCTAssertNil(days[1].objectValue?["trainingLoadBand"])
        XCTAssertEqual(days[2].objectValue?["trainingLoadBand"]?.stringValue, "nearTypical")
    }

    func testMetricsFilteringKeepsNutritionCompletenessMetadataWithinNutritionConsent() throws {
        let payload = #"{"status":"available","requestedDays":2,"validEnergyDays":1,"missingEnergyDays":1,"daysWithRecordedMeals":2,"daysWithValidIntakeEstimate":2,"daysWithValidProteinEstimate":1,"completeRecordDays":1,"intake":{"coverage":{"expectedDays":2,"availableDays":1}},"expenditure":{"coverage":{"expectedDays":2,"availableDays":2}},"deficit":{"coverage":{"expectedDays":2,"availableDays":1}},"dailyBreakdown":[{"date":"2026-10-01","nutritionRecordStatus":"complete","lastMealRecordedAt":"2026-10-01T12:30:00Z","intake":{"value":500},"expenditure":{"value":700},"deficit":{"value":200},"coverage":{"intake":{"expectedDays":1},"expenditure":{"expectedDays":1},"deficit":{"expectedDays":1}}}]}"#

        func result(allowed: Set<ProviderDataClass>, id: String) throws -> [String: JSONValue] {
            let call = ToolCall(id: id, name: "get_metrics", arguments: .object([:]))
            let messages = [
                ModelMessage(role: .assistant, content: [.toolCall(call)]),
                ModelMessage(role: .tool, content: [.toolResult(toolCallID: id, content: payload)]),
            ]
            let filtered = CloudRequestPolicyGuard.filterToolResults(
                in: messages,
                by: CloudHealthContextPolicy(provider: .qwen, allowedClasses: allowed)
            )
            guard case .toolResult(_, let text)? = filtered.last?.content.first,
                  let data = text.data(using: .utf8) else {
                throw NSError(domain: "CloudHealthContextPolicyTests", code: 1)
            }
            return try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
        }

        let nutrition = try result(allowed: [.healthNutrition], id: "metrics-nutrition-completeness")
        XCTAssertEqual(nutrition["daysWithRecordedMeals"]?.intValue, 2)
        XCTAssertEqual(nutrition["daysWithValidIntakeEstimate"]?.intValue, 2)
        XCTAssertEqual(nutrition["daysWithValidProteinEstimate"]?.intValue, 1)
        XCTAssertEqual(nutrition["completeRecordDays"]?.intValue, 1)
        XCTAssertNil(nutrition["validEnergyDays"])
        XCTAssertNil(nutrition["missingEnergyDays"])
        let nutritionDay = try XCTUnwrap(nutrition["dailyBreakdown"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(nutritionDay["nutritionRecordStatus"]?.stringValue, "complete")
        XCTAssertEqual(nutritionDay["lastMealRecordedAt"]?.stringValue, "2026-10-01T12:30:00Z")
        XCTAssertNil(nutritionDay["expenditure"])

        let activity = try result(allowed: [.healthActivity], id: "metrics-activity-completeness")
        for key in [
            "daysWithRecordedMeals", "daysWithValidIntakeEstimate", "daysWithValidProteinEstimate",
            "completeRecordDays", "validEnergyDays", "missingEnergyDays",
        ] {
            XCTAssertNil(activity[key], "\(key) must not cross into Activity-only context")
        }
        let activityDay = try XCTUnwrap(activity["dailyBreakdown"]?.arrayValue?.first?.objectValue)
        XCTAssertNil(activityDay["nutritionRecordStatus"])
        XCTAssertNil(activityDay["lastMealRecordedAt"])
        XCTAssertNil(activityDay["intake"])
    }

    func testMetricsFilteringSeparatesNutritionActivityAndCrossDomainDeficit() throws {
        let payload = #"{"status":"available","startDate":"2026-10-01","endDate":"2026-10-05","timeZone":"UTC","requestedDays":5,"validEnergyDays":5,"missingEnergyDays":0,"intake":{"total":{"value":{"low":1800,"likely":1900,"high":2000},"availability":"estimated","sourceReferences":["meal-source"]},"average":{"value":{"low":360,"likely":380,"high":400},"availability":"estimated"},"coverage":{"expectedDays":5,"availableDays":4,"partialDays":1,"unavailableDays":0,"pendingRecomputeDays":0}},"expenditure":{"total":{"value":{"low":2200,"likely":2300,"high":2400},"availability":"observed","sourceReferences":["workout-source"]},"average":{"value":{"low":440,"likely":460,"high":480},"availability":"observed"},"coverage":{"expectedDays":5,"availableDays":5,"partialDays":0,"unavailableDays":0,"pendingRecomputeDays":0}},"deficit":{"total":{"value":{"low":200,"likely":400,"high":600},"availability":"estimated"},"average":{"value":{"low":40,"likely":80,"high":120},"availability":"estimated"},"coverage":{"expectedDays":5,"availableDays":3,"partialDays":1,"unavailableDays":1,"pendingRecomputeDays":0}},"averageDailyDeficit":{"value":{"low":40,"likely":80,"high":120},"availability":"estimated"},"projectedWeightLossKg":{"value":0.25,"availability":"estimated"},"projectedWeightLossNote":"按累计缺口粗略折算","proteinG":{"total":{"value":90,"availability":"observed"},"average":{"value":18,"availability":"observed"},"coverage":{"expectedDays":5,"availableDays":5}},"fatG":{"total":{"value":60,"availability":"observed"},"average":{"value":12,"availability":"observed"},"coverage":{"expectedDays":5,"availableDays":5}},"carbsG":{"total":{"value":200,"availability":"observed"},"average":{"value":40,"availability":"observed"},"coverage":{"expectedDays":5,"availableDays":5}},"energyQuality":"estimated","dailyBreakdown":[{"date":"2026-10-01","intake":{"value":{"low":400,"likely":450,"high":500},"availability":"estimated","sourceReferences":["meal-one"]},"expenditure":{"value":{"low":500,"likely":550,"high":600},"availability":"observed","sourceReferences":["workout-one"]},"deficit":{"value":{"low":0,"likely":100,"high":200},"availability":"estimated"},"proteinG":{"value":20,"availability":"observed"},"fatG":{"value":12,"availability":"observed"},"carbsG":{"value":40,"availability":"observed"},"coverage":{"intake":{"expectedDays":1,"availableDays":1},"expenditure":{"expectedDays":1,"availableDays":1},"deficit":{"expectedDays":1,"availableDays":1},"proteinG":{"expectedDays":1,"availableDays":1}},"energyQuality":"estimated","requiresRecompute":true,"projectionVersion":"private-version"}],"truncated":false,"nextStartDate":null}"#

        func result(allowed: Set<ProviderDataClass>, id: String) throws -> [String: JSONValue] {
            let call = ToolCall(id: id, name: "get_metrics", arguments: .object([:]))
            let messages = [
                ModelMessage(role: .assistant, content: [.toolCall(call)]),
                ModelMessage(role: .tool, content: [.toolResult(toolCallID: id, content: payload)]),
            ]
            let filtered = CloudRequestPolicyGuard.filterToolResults(
                in: messages,
                by: CloudHealthContextPolicy(provider: .qwen, allowedClasses: allowed)
            )
            guard case .toolResult(_, let text)? = filtered.last?.content.first else {
                throw NSError(domain: "CloudHealthContextPolicyTests", code: 1)
            }
            let data = try XCTUnwrap(text.data(using: .utf8))
            let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
            return try XCTUnwrap(decoded.objectValue)
        }

        let nutrition = try result(allowed: [.healthNutrition], id: "metrics-nutrition")
        XCTAssertNotNil(nutrition["intake"])
        XCTAssertNotNil(nutrition["proteinG"])
        XCTAssertNil(nutrition["expenditure"])
        XCTAssertNil(nutrition["deficit"])
        XCTAssertNil(nutrition["averageDailyDeficit"])
        XCTAssertNil(nutrition["projectedWeightLossKg"])
        XCTAssertNil(nutrition["validEnergyDays"])
        XCTAssertNil(nutrition["missingEnergyDays"])
        XCTAssertEqual(nutrition["status"]?.stringValue, "partial")
        let nutritionDay = try XCTUnwrap(nutrition["dailyBreakdown"]?.arrayValue?.first?.objectValue)
        XCTAssertNotNil(nutritionDay["intake"])
        XCTAssertNotNil(nutritionDay["proteinG"])
        XCTAssertNil(nutritionDay["expenditure"])
        XCTAssertNil(nutritionDay["deficit"])
        XCTAssertNil(nutritionDay["requiresRecompute"])
        XCTAssertNil(nutritionDay["projectionVersion"])
        XCTAssertNil(nutritionDay["coverage"]?.objectValue?["expenditure"])
        XCTAssertNil(nutritionDay["coverage"]?.objectValue?["deficit"])

        let activity = try result(allowed: [.healthActivity], id: "metrics-activity")
        XCTAssertNotNil(activity["expenditure"])
        XCTAssertNil(activity["intake"])
        XCTAssertNil(activity["proteinG"])
        XCTAssertNil(activity["deficit"])
        XCTAssertNil(activity["averageDailyDeficit"])
        XCTAssertNil(activity["projectedWeightLossKg"])
        XCTAssertNil(activity["validEnergyDays"])
        XCTAssertNil(activity["missingEnergyDays"])
        XCTAssertEqual(activity["status"]?.stringValue, "available")
        let activityDay = try XCTUnwrap(activity["dailyBreakdown"]?.arrayValue?.first?.objectValue)
        XCTAssertNotNil(activityDay["expenditure"])
        XCTAssertNil(activityDay["intake"])
        XCTAssertNil(activityDay["proteinG"])
        XCTAssertNil(activityDay["deficit"])
        XCTAssertNil(activityDay["energyQuality"])
        XCTAssertEqual(Set(activityDay["coverage"]?.objectValue?.keys.map { $0 } ?? []), ["expenditure"])

        let both = try result(allowed: [.healthNutrition, .healthActivity], id: "metrics-both")
        XCTAssertNotNil(both["intake"])
        XCTAssertNotNil(both["expenditure"])
        XCTAssertNotNil(both["deficit"])
        XCTAssertNotNil(both["averageDailyDeficit"])
        XCTAssertNotNil(both["projectedWeightLossKg"])
        XCTAssertEqual(both["status"]?.stringValue, "partial")
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
