#!/usr/bin/env python3
"""Validate static contracts and fixtures for PLAN_v3 gate-03-agent-provider.

This validator uses explicit paths and never traverses the private OCR source.
Provider runtime behavior is proven by fake-transport Simulator tests, not live API calls.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_text(path: Path, errors: list[str]) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        errors.append(f"could not read {path.relative_to(ROOT)}: {error}")
        return ""


def require_text(
    path: Path,
    needles: list[str],
    errors: list[str],
    *,
    normalize_whitespace: bool = False,
    ignore_case: bool = False,
) -> None:
    if not path.is_file():
        errors.append(f"missing {path.relative_to(ROOT)}")
        return
    text = read_text(path, errors)
    if normalize_whitespace:
        text = " ".join(text.split())
    if ignore_case:
        text = text.casefold()
    for needle in needles:
        expected = " ".join(needle.split()) if normalize_whitespace else needle
        if ignore_case:
            expected = expected.casefold()
        if expected not in text:
            errors.append(f"{path.relative_to(ROOT)} is missing {needle}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report")
    args = parser.parse_args()
    errors: list[str] = []

    required_files = [
        "Densoso/Infrastructure/LLM/LLMTypes.swift",
        "Densoso/Infrastructure/LLM/ProviderError.swift",
        "Densoso/Infrastructure/LLM/ProviderHTTPTransport.swift",
        "Densoso/Infrastructure/LLM/DeepSeekProvider.swift",
        "Densoso/Infrastructure/LLM/QwenProvider.swift",
        "Densoso/Infrastructure/LLM/ProviderConfiguration.swift",
        "Densoso/Application/Agent/AgentBudget.swift",
        "Densoso/Application/Agent/AgentProviderContextPolicy.swift",
        "Densoso/Application/Agent/AgentReasoningPolicy.swift",
        "Densoso/Application/Agent/AgentEvents.swift",
        "Densoso/Application/Agent/AgentIntent.swift",
        "Densoso/Application/Agent/AgentTurnContract.swift",
        "Densoso/Application/Agent/ToolSchemaValidator.swift",
        "Densoso/Application/Usage/ProviderUsageLedger.swift",
        "Densoso/Application/Usage/PricingDescriptorCatalog.swift",
        "Densoso/Persistence/Schemas/DensosoSchemaV9.swift",
        "Densoso/Application/Formatting/AssistantBlock.swift",
        "Densoso/Application/Formatting/RestrictedMarkdownRenderer.swift",
        "Densoso/Views/Components/AssistantBlockView.swift",
        "Densoso/Agent/Tools/CreateWorkoutPlanTool.swift",
        "Densoso/Agent/Tools/GetMetricsTool.swift",
        "Densoso/Agent/ToolRegistry.swift",
        "docs/gates/gate-03-agent-provider.md",
    ]
    for relative in required_files:
        if not (ROOT / relative).is_file():
            errors.append(f"missing {relative}")

    require_text(
        ROOT / "docs/gates/gate-03-agent-provider.md",
        [
            "Daily-check-in tool arguments are checked against the current user turn",
            "a note absent from the user's words",
            "do not enter HealthKit projections",
            "PricingDescriptor",
            "hard per-request cost cap",
            "conservative cost estimate",
            "legacy in-flight request",
            "last eight complete turns",
            "64 messages",
            "96 KiB input estimate",
            "Pricing checks cover exact provider/model/capability matching and known descriptor entries",
            "retain unknown cost",
            "stable 64-row keyset pages",
            "cross-page currency fixture",
            "Normalize local and cloud turns as `AgentTurnResult`",
            "Local capture detection is a proposal only",
            "workout cannot be classified as a future workout plan",
            "Read the Agent's requested-day schedule through the bounded repository query",
            "Load confirmed workout and training-plan entries for the DailyLoop/Watch snapshot",
            "visible and resumable conversation messages",
            "current-request resume filter",
            "Reset conversation messages and Agent request history in stable 64-row pages",
            "stable 64-row",
            "invalid rows and valid ties across the page boundary",
        ],
        errors,
        normalize_whitespace=True,
        ignore_case=True,
    )
    require_text(
        ROOT / "Densoso/Application/Usage/ProviderUsageLedger.swift",
        [
            "enum PricingDescriptorOrigin",
            "struct PricingDescriptor",
            "struct ProviderRequestCostEstimate",
            "protocol PricingDescriptorSource",
            "struct StaticPricingDescriptorSource",
            "maximumRequestCostEstimate(",
            "recordWithCostAvailability(",
            "ProviderRequestExecutor.defaultMaximumAttempts",
            "usage.cachedInputTokens <= usage.inputTokens",
            "usage.requestID == nil || usage.requestID == requestID",
            'rateVersion: estimate == nil ? "unknown"',
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso/Application/Usage/PricingDescriptorCatalog.swift",
        [
            "enum PricingDescriptorCatalog",
            "model: \"deepseek-flash\"",
            "model: \"qwen-flash\"",
            "version: \"deepseek-2026-09-10-peak-upper-bound\"",
            "inputMicrosPerMillionTokens: 300_000",
            "cachedInputMicrosPerMillionTokens: 300_000",
            "outputMicrosPerMillionTokens: 1_200_000",
            "checkedOn: \"2026-10-23\"",
            "cachedInputMicrosPerMillionTokens: 150_000",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "ProviderUsageLedgerTests.swift",
        [
            "testQwenSpeechUsageWithoutPricingDescriptorKeepsCostUnknown",
            "testMissingCachedPriceAndUnlistedVisionModelKeepCostUnknown",
            "testPreflightCostUsesInputUpperBoundMaximumOutputAndRetryAttempts",
            "testUsageIdentityImageCountAndLatencyAreRetainedInLedgerSummary",
            "testUsageWithMismatchedRequestIdentityIsRejectedBeforePersistence",
            "testLegacyUsagePayloadDecodesWithUnknownImageAndLatencyMetadata",
        ],
        errors,
    )

    require_text(
        ROOT / "Densoso" / "Infrastructure" / "LLM" / "ProviderError.swift",
        [
            "configurationMissing", "consentRequired", "unauthorized", "rateLimited",
            "timeout", "network", "server", "malformedResponse", "contentRejected",
            "cancelled", "budgetExceeded", "budgetUnavailable", "requestModelMismatch",
            "budgetUnavailable",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "LLM" / "ProviderHTTPTransport.swift",
        ["defaultMaximumRetries = 2", "defaultMaximumAttempts", "Retry-After", "Task.checkCancellation", "deadline"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "LLM" / "ProviderConfiguration.swift",
        [
            'static let deepSeekFlashModel = "deepseek-flash"',
            'static let deepSeekResponsesEndpoint = URL(string: "https://api.deepseek.com/responses")!',
            "static func deepSeekCapabilities(for model: String, endpoint: URL)",
            "guard model == deepSeekFlashModel",
            "endpoint == deepSeekResponsesEndpoint",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "LLM" / "DeepSeekProvider.swift",
        [
            "endpoint: URL = ProviderCapabilityCatalog.deepSeekResponsesEndpoint",
            "model: String = ProviderCapabilityCatalog.deepSeekFlashModel",
            "ProviderCapabilityCatalog.deepSeekCapabilities(for: model, endpoint: endpoint)",
            "input_image",
            "response.output_text.delta",
            "requestID: request.requestID",
            "imageCount: request.imageCount",
            "latencyMilliseconds: Self.latencyMilliseconds(since: startedAt)",
            "if let gate = request.preSerializationGate",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Infrastructure" / "LLM" / "DeepSeekProviderContractTests.swift",
        [
            'XCTAssertEqual(sent.url?.absoluteString, "https://api.deepseek.com/responses")',
            'XCTAssertEqual(object["model"] as? String, "deepseek-flash")',
            "usage.imageCount == 1",
            "usage.requestID == requestID",
            "testRetiredDeepSeekVisionCompatibilityAliasIsNotVisionCapable",
            "testPreSerializationConsentCheckStopsBeforeDeepSeekRequestIsSent",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Infrastructure" / "LLM" / "QwenProviderContractTests.swift",
        (
            "usage.requestID == requestID",
            "usage.imageCount == 0",
            "usage.latencyMilliseconds ?? -1",
            "testPreSerializationConsentCheckStopsBeforeQwenRequestIsSent",
        ),
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "LLM" / "QwenProvider.swift",
        ["if let gate = request.preSerializationGate"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Application" / "Agent" / "AgentReasoningPolicy.swift",
        ["forUserMessage", "return .high", "return .max"],
        errors,
    )
    require_text(
        ROOT / "Densoso/Application/Agent/AgentTurnContract.swift",
        [
            "static func local",
            "static func cloud",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso/Application/Agent/AgentIntent.swift",
        [
            "struct HealthQuestion: Codable",
            "struct HistoryQuery: Codable",
            "enum AgentIntent: Codable, Equatable, Sendable",
            "case answerHealthQuestion(HealthQuestion)",
            "case recordMeal(MealIntent)",
            "case recordWeight(WeightIntent)",
            "case createWorkoutPlan(WorkoutIntent)",
            "case createTrainingPlan(TrainingPlanIntent)",
            "case dailyCheckIn(CheckInIntent)",
            "case queryHistory(HistoryQuery)",
            "case recordUserPreference(UserPreferenceIntent)",
            "case captureProposal(LocalRecordSuggestion)",
            "case answer(String)",
            "Read-intent cases require explicit adapter metadata",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso/Services/LocalIntelligenceService.swift",
        [
            "case workoutPlan = \"workoutplan\"",
            "hasMatchingUserIntent",
            "case .workoutPlan:",
            "Never classify a completed workout as a plan",
            "userText: text",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso/Views/ChatScreen.swift",
        [
            "AgentTurnContract.local(result)",
            "AgentTurnContract.cloud(reply: response.text, stagedActions: stagedActions)",
            "case .captureProposal(let suggestion)",
            "原话保留在编辑框",
        ],
        errors,
    )
    for provider_file in ("DeepSeekProvider.swift", "QwenProvider.swift"):
        require_text(
            ROOT / "Densoso" / "Infrastructure" / "LLM" / provider_file,
            ["continuation.onTermination", "task.cancel()"],
            errors,
        )
    require_text(
        ROOT / "Densoso" / "Agent" / "AgentSession.swift",
        [
            "AgentBudgetTracker", "toolCallsCount: tracker.toolCalls",
            "providerRoundsCount: tracker.providerRounds", "cancelActiveRequest",
            "governanceRepository.isConsentGranted", "latestEvent", "sendEvents",
            "cancelled(requestID:", "beginAgentRequest", "resumeHistory",
            "requestSnapshot.budget", "requestSnapshot.consumption",
            "updateAgentRequestState",
            "preSerializationGate:", "withCurrentSendConsentSerialization(",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Application" / "Agent" / "AgentReasoningPolicy.swift",
        [
            "提取意图", "训练计划", "今天怎么安排", "return .max", "return .high", "return .none",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "AgentReasoningPolicyTests.swift",
        [
            "testWeightLoggingUsesNoReasoning",
            "testHealthAnalysisUsesHighReasoning",
            "testLongRangeTrainingPlanUsesMaximumReasoning",
            "testOrdinaryQuestionUsesLowReasoning",
            "testMealDraftUsesLowReasoning",
            "testIntentExtractionUsesNoReasoning",
            "testDailyRecommendationUsesHighReasoning",
            "testComplexPlanningUsesMaximumReasoning",
        ],
        errors,
    )
    agent_text = read_text(ROOT / "Densoso" / "Agent" / "AgentSession.swift", errors)
    if "DeepSeekClient" in agent_text or "ModelContext" in agent_text:
        errors.append("AgentSession must remain provider-neutral and free of ModelContext")
    require_text(
        ROOT / "Densoso" / "Agent" / "AgentSession.swift",
        [
            "用户明确表达后记录",
            "绝不能从 HealthKit、生理数据或历史行为推断",
            "不得自动加入云端上下文",
            "只有用户明确询问已记录的个人偏好时，才调用 get_user_preferences",
            "func userPreferences(limit:",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Application" / "Agent" / "AgentRepositories.swift",
        ["struct AgentUserPreference", "AgentUserPreferencesLimits", "func userPreferences(limit:"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "SwiftDataAgentRepository.swift",
        [
            "func userPreferences(limit:",
            "UserPreferenceSource.userReported.rawValue",
            "UserPreferenceCategory(rawValue: record.categoryRaw)",
            "static let userPreferenceFetchBatchSize = 64",
            "sourceActionKey > cursorSourceActionKey",
            "descriptor.fetchLimit = Self.userPreferenceFetchBatchSize",
            "AgentUserPreference(category:",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "SwiftDataProviderGovernanceRepository.swift",
        [
            "static let monthlyUsageBatchSize = 64",
            "private struct UsageCursor",
            "record.usageKey > cursorUsageKey",
            "descriptor.fetchLimit = Self.monthlyUsageBatchSize",
            "record.imageCount = max(usage.imageCount, 0)",
            "record.requestID = requestID",
            "record.latencyMilliseconds = usage.latencyMilliseconds",
            'record.rateVersion != "unknown"',
            'record.currency != "unavailable"',
            "averageLatencyMilliseconds:",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "Tools" / "GetUserPreferencesTool.swift",
        ["get_user_preferences", "returnedCount", "hasMore", "maximumOutputCharacters", "noPreferences"],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "GetUserPreferencesToolTests.swift",
        [
            "testToolUsesStrictEmptyReadOnlySchemaAndExplicitRequestPolicy",
            "testRepositoryReturnsOnlyConfirmedUserReportedCategoriesWithoutWritesOrIDs",
            "testRepositoryPagesInvalidRowsAndPreservesIDOrderAcrossTimestampCutoff",
            "testOutputSizeLimitRemovesItemsAndReportsHasMore",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests/Privacy/ProviderLogRedactionTests.swift",
        ["testPinnedQwenVisionSnapshotIsAnAllowlistedModelIdentifier"],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "DailyLoopSnapshotCompositionTests.swift",
        [
            "testComposerUsesMatchingExistingBriefAndPreservesOptionalState",
            "testComposerKeepsMissingMorningAndDaytimeSummariesNil",
            "testComposerMarksOldHealthBriefStaleAndChangesFingerprintWithItsSource",
            "testComposerCarriesSafeErrorStateWithoutPublishingHealthFingerprint",
            "stale-plan",
            "distant-plan",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Application" / "DailyLoop" / "DailyLoopSnapshotService.swift",
        [
            "struct DailyLoopSnapshotComposer",
            "healthIntelligenceService.dailyBrief",
            "dailyBriefSourceFingerprint",
            "dailyBriefValidatedAt",
            "sourceFingerprint",
            "projectionVersion",
            "refreshState",
            "coverage",
            "func refreshSnapshot(asOf date: Date = Date()) async throws -> DailyLoopSnapshot",
            "agentSession.pendingActions",
            "plansThroughTomorrow",
            "scheduledAt >= dayStart",
            "DailyLoopSnapshot(",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Services" / "HealthProjectionActor.swift",
        [
            "private static let confirmedPlanFetchBatchSize = 64",
            "func dailyLoopSnapshot(",
            "let plans = try loadConfirmedPlanEntries(asOf: date)",
            "descriptor.fetchLimit = Self.confirmedPlanFetchBatchSize",
            "descriptor.fetchOffset = offset",
            "planWindow.contains(scheduledAt)",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "HealthProjectionActorTests.swift",
        [
            "testConfirmedPlanEntriesDecodeAndSortBothPlanTypesAndIgnoreOrdinaryEvents",
            "testConfirmedPlanEntriesPageHistoricalPlansAndDailySnapshotRetainsOnlyCurrentSessions",
            "testDailyLoopSnapshotRetainsTenEarliestPlanSessionsAcrossPages",
        ],
        errors,
    )

    require_text(
        ROOT / "Densoso" / "Persistence" / "Schemas" / "DensosoSchemaV5.swift",
        [
            "AgentRequestRecord", "requestID", "conversationID", "startedAt",
            "absoluteDeadline", "providerRoundsUsed", "toolCallsUsed", "inputTokens",
            "cachedInputTokens", "outputTokens", "reasoningTokens", "resumeCount",
            "containsTransientImage", "stateRaw",
            "DailyCheckInRecord", "subjectiveSleepRaw", "userReported",
            "UserPreferenceRecord", "categoryRaw", "sourceActionKey",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Persistence" / "Schemas" / "DensosoSchemaV9.swift",
        (
            "DensosoSchemaV8.models.filter",
            "ObjectIdentifier($0) != ObjectIdentifier(DensosoSchemaV4.ProviderUsageRecord.self)",
            "ProviderUsageRecord.self",
            "var imageCount: Int = 0",
            "var requestID: UUID?",
            "var latencyMilliseconds: Int?",
            "AgentRequestCostBudgetRecord",
            "maximumCostMicros",
            "reservedCostMicros",
            "lastReservedProviderRound",
            "pricingVersion",
        ),
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Application" / "Agent" / "AgentBudget.swift",
        ("defaultMaximumCostMicros", "maximumCostMicros"),
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "SwiftDataAgentRepository.swift",
        [
            "beginAgentRequest", "absoluteDeadline", "resumeCount", "containsTransientImage",
            "updateAgentRequestConsumption", "reserveAgentRequestCost(",
            "markAgentRequestCostUnavailable(", "ensureCostBudgetRecord(",
            "AgentRequestCostBudgetRecord",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "AgentSession.swift",
        [
            "func send(multimodalRequest: MultimodalModelRequest",
            "containsTransientImage: multimodalRequest.image != nil || !multimodalRequest.mealEvidence.isEmpty",
            "transientMealImageEvidence = multimodalRequest.mealEvidence",
            "providerMessagesIncludingTransientMealEvidence(",
            "transientMealEvidenceMessage",
            "requestSnapshot.resumeCount > 0",
            "AgentError.transientImageRequired",
            "withoutSensitiveTransientContent",
            "AgentProviderContextPolicy.boundedContext(",
            "maximumRequestCostEstimate(",
            "reserveAgentRequestCost(",
            "recordWithCostAvailability(",
            "if !costIsPriced",
            "usage.capability == .text",
            "reportedModel == selectedModel",
            "markAgentRequestCostUnavailable(",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Application" / "Agent" / "AgentProviderContextPolicy.swift",
        (
            "maximumRecentTurns",
            "maximumMessages",
            "maximumEstimatedInputBytes",
            "currentTurnStartIndex",
            "estimatedInputTokenUpperBound",
        ),
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "AgentRequestResumeTests.swift",
        [
            "testInterruptedRequestResumesWithPersistedRemainingBudgetAndUsage",
            "testV4StoreMigratesToV5AndAddsAnEmptyRequestLedger",
            "testPerRequestCostReservationPersistsAndCannotResetOnResume",
            "testLegacyInterruptedRequestWithoutProviderIdentityFailsClosedBeforeCall",
            "resumeCount", "cachedInputTokens", "reasoningTokens",
            "containsTransientImage",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "DensosoMigrationTests.swift",
        ("testV8MigrationMarksPriorRoundRequestCostUnavailableWithoutProviderIdentity",),
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "AgentProviderContextPolicyTests.swift",
        ("testProviderHistoryKeepsRecentWholeTurnsAndTheCurrentTurn", "testCurrentTurnOverBudgetFailsBeforeProviderInvocation"),
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "AgentCoordinatorTests.swift",
        (
            "testProviderReasoningContinuesInMemoryButIsNeverPersisted",
            "testUnpricedProviderRequestCompletesWithUnavailableCostAccounting",
            "testCostCapIsReservedBeforeProviderOrToolInvocation",
        ),
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "MultimodalAgentImageTests.swift",
        [
            "testImageInputUsesAgentSessionAndStagesMealWithoutDirectCommitOrRawMediaPersistence",
            "testInterruptedImageRequestFailsClosedUntilImageIsReattachedAndKeepsBudget",
            "testEvidenceOnlyRequestUsesEphemeralProviderMessageWithoutImageConsentOrPersistence",
            "testInterruptedEvidenceOnlyRequestRequiresNewRequestToReprovideEvidence",
            "testEvidenceOnlyRequestBoundsTransientEvidence",
            "testImageRequiresVisionCapabilityAndSeparateMealImageConsent",
            "transientImageRequired",
            "PRIVATE-OCR-EVIDENCE-MUST-NOT-PERSIST",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "SwiftDataAgentRepository.swift",
        ["func recentMeals", "AgentRecentMeal", "startDate <= endDate"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "SwiftDataAgentRepository.swift",
        [
            "func schedule(on date: Date)",
            "static let scheduleEventFetchBatchSize = 64",
            "descriptor.fetchLimit = Self.scheduleEventFetchBatchSize",
            "descriptor.fetchOffset = eventOffset",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "SwiftDataProviderGovernanceRepository.swift",
        [
            "predicate: #Predicate { $0.consentKey == key }",
            "predicate: #Predicate { $0.usageKey == usageKey }",
            "record.provider == providerRawValue",
            "record.createdAt >= monthStart",
            "record.createdAt < monthEnd",
            "descriptor.fetchLimit = 1",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "SwiftDataProviderGovernanceQueryTests.swift",
        [
            "testConsentAndUsageDedupResolveExactKeysWithoutDuplicatingRows",
            "testMonthlyUsageQueriesProviderAndHalfOpenDateWindowAndKeepsUnknownCost",
            "testMonthlyUsagePagesLastCrossCurrencyRecordAndFiltersProviderWindow",
            "records.first?.imageCount",
            "records.first?.requestID",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "SwiftDataAgentRepository.swift",
        [
            "func dailyMetrics(from startDate: Date, through endDate: Date)",
            "guard startDate <= endDate else { return [] }",
            "#Predicate<DailyMetrics>",
            "metric.date >= startDate && metric.date <= endDate",
            "static let dailyMetricFetchBatchSize = 64",
            "descriptor.fetchLimit = Self.dailyMetricFetchBatchSize",
            r"SortDescriptor(\DailyMetrics.date)",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "SwiftDataAgentRepository.swift",
        [
            "static let messageFetchBatchSize = 64",
            "private func fetchMessageData(conversationID: UUID, excludingRequestID: UUID?)",
            "descriptor.fetchLimit = Self.messageFetchBatchSize",
            "message.id > cursorID",
            "static let conversationResetBatchSize = 64",
            "messageDescriptor.fetchLimit = Self.conversationResetBatchSize",
            "message.ordinal > cursorOrdinal",
            "requestDescriptor.fetchLimit = Self.conversationResetBatchSize",
            "request.requestID > cursorRequestID",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "AgentDailyMetricsRepositoryTests.swift",
        [
            "testRepositoryFiltersToInclusiveDateRangeAndSortsResults",
            "testRepositoryPagesAllMetricsAcrossStableDatePages",
            "testRepositoryReturnsEmptyForInvertedDateRange",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "Tools" / "GetMetricsTool.swift",
        ["maximumRangeDays = 90", "dailyBreakdownPageSize = 4", "DailyMetricsUsabilityPolicy.aggregateSignedRanges", "nextStartDate"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "ToolRegistry.swift",
        ["AgentToolOutputLimiter.limit(output)", "maximumUTF8Bytes", "tool_output_limit_exceeded"],
        errors,
    )
    tool_registry_path = ROOT / "Densoso" / "Agent" / "ToolRegistry.swift"
    if tool_registry_path.is_file() and "String(output.prefix(8_192))" in tool_registry_path.read_text(encoding="utf-8"):
        errors.append("Densoso/Agent/ToolRegistry.swift truncates tool output by character prefix")
    require_text(
        ROOT / "DensosoTests" / "Application" / "GetMetricsToolTests.swift",
        ["testResponseKeepsPartialCoverageAndPagesDailyBreakdownAsValidJSON", "testNoValidDaysReturnsInsufficientDataWithoutZeroTotals"],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "AgentToolOutputLimiterTests.swift",
        ["testOutputWithinUTF8BudgetIsPreserved", "testOversizedOutputReturnsValidStructuredJSONInsteadOfCharacterTruncation"],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "ConversationPersistenceTests.swift",
        [
            "testMessagePagesPreserveOrdinalAndResumeFilterAcrossPageBoundary",
            "testResetPagesMessagesAndRequestsAcross64RowBoundaries",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "GetRecentMealsToolTests.swift",
        [
            "testQueryWindowAndOutputUseLocalDaysSortNewestFirstAndEnforceLimit",
            "testSizeBoundReportsThatAdditionalMealsRemain",
            "testToolHasStrictReadOnlySchemaAndRejectsOutOfRangeArguments",
            "testRepositoryUsesUUIDAsStableTieBreakBeforeApplyingFetchLimit",
            "testRepositoryReturnsBoundedSummariesWithoutWritingOrExposingStoredFields",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "SwiftDataAgentRepository.swift",
        ["func recentWorkouts", "WorkoutRecord", "workout.durationMinutes > 0"],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "GetRecentWorkoutsToolTests.swift",
        [
            "testQueryWindowAndOutputUseLocalDaysSortNewestFirstAndEnforceLimit",
            "testToolHasStrictReadOnlySchemaAndRejectsOutOfRangeArguments",
            "testRepositoryReturnsCompletedRecordsOnlyWithoutWritesOrStoredFields",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "Tools" / "GetGoalTool.swift",
        ["get_goal", "goalProvider", "unavailable"],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "GetTodayPlanToolTests.swift",
        ["testScheduleFindsHistoricalTrainingSessionAfterFirstPage"],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "GetGoalToolTests.swift",
        [
            "testToolUsesStrictEmptyReadOnlySchema",
            "testMissingOrEmptyGoalsReturnUnavailableWithoutDefaults",
            "testModelActorReturnsOnlyCurrentEffectiveGoalAndReadDoesNotWrite",
        ],
        errors,
    )
    require_text(
        ROOT / "Packages" / "DensosoDomain" / "Sources" / "DensosoDomain" / "DailyCheckIn.swift",
        [
            "public enum UserReportedEnergy",
            "public enum UserReportedStress",
            "public enum SubjectiveSleepQuality",
        ],
        errors,
    )
    require_text(
        ROOT / "Packages" / "DensosoDomain" / "Tests" / "DensosoDomainTests" / "DailyCheckInTests.swift",
        ["testDailyCheckInRepresentsOnlyUserReportedFields"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "Tools" / "StageDailyCheckInTool.swift",
        [
            "stage_daily_checkin",
            "ConfirmationRequiredTool",
            "UserReportedEnergy",
            "DailyCheckIn",
            "DailyCheckInSelfReportResolver().validate",
            "context.currentMealUserText()",
            "let asOf = Date()",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "Tools" / "DailyCheckInSelfReportResolver.swift",
        [
            "containsUnnegated",
            "modelValueNotSupported",
            "noteNotReported",
            "otherPerson",
            "ambiguousNegationField(in: text)",
            "dateNotSupported",
            "guard occurredAt <= date",
            "explicitDays(in: rawText)",
            "\"我妈\"",
            "\"我爸\"",
            "\"mymom\"",
            "\"mydad\"",
            "压力",
            "notstressed",
            "nottired",
        ],
        errors,
    )
    require_text(
        ROOT / "Packages" / "DensosoDomain" / "Sources" / "DensosoDomain" / "ActionPayload.swift",
        ["case dailyCheckIn(DailyCheckIn)", "CanonicalDailyCheckIn", "case .dailyCheckIn"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "SwiftDataConfirmationRepository.swift",
        ["case .dailyCheckIn(let checkIn)", "sourceRaw: \"userReported\"", "healthSyncState = .notApplicable"],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "DailyCheckInConfirmationTests.swift",
        [
            "testToolCreatesOnlyPendingActionUntilUserConfirms",
            "testRejectingCheckInNeverPersistsTheUserReportedFact",
            "testV4StoreMigratesToV5WithAnEmptyCheckInLedger",
            "testSelfReportResolverAcceptsExplicitFieldsAndVerbatimNote",
            "testSelfReportResolverDoesNotInferStressFromFatigueAndSleep",
            "testSelfReportResolverRejectsContradictionsOtherPeopleAndInventedNotes",
            "testSelfReportResolverRejectsUnsupportedDateAndHonorsNegation",
            "testSelfReportResolverRejectsConflictingOrMalformedExplicitDates",
            "testSelfReportResolverRejectsDoubleNegationAndMixedEnergySignals",
            "testSameDayCheckInsAppendIdempotentlyAndSubjectiveReadUsesLatest",
            "testAgentDoesNotStageInferredStressButStagesAndCommitsExplicitCheckIn",
        ],
        errors,
    )
    require_text(
        ROOT / "Packages" / "DensosoDomain" / "Sources" / "DensosoDomain" / "UserPreference.swift",
        ["UserPreferenceCategory", "food", "exercise", "communication", "userReported"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "Tools" / "StageUserPreferenceTool.swift",
        ["stage_user_preference", "ConfirmationRequiredTool", "UserPreferenceCategory", "UserPreference("],
        errors,
    )
    require_text(
        ROOT / "Packages" / "DensosoDomain" / "Sources" / "DensosoDomain" / "ActionPayload.swift",
        ["case userPreference(UserPreference)", "CanonicalUserPreference", "case .userPreference"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "SwiftDataConfirmationRepository.swift",
        ["case .userPreference(let preference)", "UserPreferenceRecord", "sourceRaw: preference.source.rawValue"],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "UserPreferenceConfirmationTests.swift",
        [
            "testToolCreatesOnlyPendingActionUntilConfirmedPreferenceIsSaved",
            "testRejectingPreferenceNeverWritesPreferenceRecord",
            "testV4StoreMigratesToV5WithAnEmptyPreferenceLedger",
        ],
        errors,
    )

    require_text(
        ROOT / "Densoso" / "Agent" / "Tools" / "LogMealTool.swift",
        ["\"dishes\": .array", "LogMealArguments", "additionalProperties: false"],
        errors,
    )
    if "dishesJSON" in read_text(ROOT / "Densoso" / "Agent" / "Tools" / "LogMealTool.swift", errors):
        errors.append("log_meal still accepts stringified nested JSON")
    require_text(
        ROOT / "Densoso" / "Agent" / "Tools" / "CreateTrainingPlanTool.swift",
        [
            'name: "create_training_plan"',
            "maximumItems: TrainingPlanDraft.maximumSessionCount",
            "TrainingSessionDraft.Intensity.allCases",
            "return .trainingPlan(draft)",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "ToolRegistry.swift",
        [
            "ToolSchemaValidator.validate",
            "SearchFoodTool",
            "GetTodayPlanTool",
            "GetScheduleTool",
            "CreateWorkoutPlanTool",
            "CreateTrainingPlanTool",
            "GetRecentMealsTool",
            "GetRecentWorkoutsTool",
            "GetGoalTool",
            "GetUserPreferencesTool",
            "StageDailyCheckInTool",
            "StageUserPreferenceTool",
            "GetHealthHistoryTool",
            "GetPendingActionsTool",
            "8_192",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "ToolSchemaTests.swift",
        [
            "registry.toolDefinitions.count, 20",
            "testSearchFoodIsStrictReadOnlyV2Tool",
            "testSearchFoodUsesV2AxesLimitsTopThreeAndOmitsStorageIdentifiers",
            "testGetTodayPlanHasEmptyStrictReadOnlySchema",
            "testGetTodayPlanResponseUsesLocalDayAndBoundsEntries",
            "create_training_plan",
            "testCreateTrainingPlanUsesBoundedStructuredWorkoutAndRestDays",
            "get_user_preferences",
            "testPendingActionsToolOnlyReturnsUnexpiredUncommittedSummaries",
            "testPendingActionsToolAcceptsOnlyAnEmptyReadOnlyRequest",
            "testPendingActionsToolBoundsResultsAndReportsRemainingActions",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "Tools" / "SearchFoodTool.swift",
        [
            'name: "search_food"',
            "FoodResolverV2(catalog: catalog).resolve",
            "maximumCandidates = 3",
            "confirmedFoodHistoryIDs",
            "requiresConfirmation",
            "finalScore",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "Tools" / "GetTodayPlanTool.swift",
        [
            'name: "get_today_plan"',
            "properties: [:]",
            "required: []",
            "context.schedule(on: now)",
            "maximumEvents = 12",
            "hasMore",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Services" / "KeychainStore.swift",
        ["model_studio_api_key", "saveModelStudioAPIKey", "readModelStudioAPIKey"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Application" / "Formatting" / "RestrictedMarkdownRenderer.swift",
        ["containsForbiddenMarkup", "sanitizeLinks", "plainText", 'scheme?.lowercased() == "https"'],
        errors,
    )

    test_files = [
        "DensosoTests/Application/AgentReasoningPolicyTests.swift",
        "DensosoTests/Application/AgentTurnContractTests.swift",
        "DensosoTests/LocalIntelligenceSuggestionTests.swift",
        "DensosoTests/Infrastructure/LLM/DeepSeekProviderContractTests.swift",
        "DensosoTests/Infrastructure/LLM/QwenProviderContractTests.swift",
        "DensosoTests/Infrastructure/LLM/ProviderRetryPolicyTests.swift",
        "DensosoTests/Application/AgentCoordinatorTests.swift",
        "DensosoTests/Application/SwiftDataProviderGovernanceQueryTests.swift",
        "DensosoTests/Application/AgentDailyMetricsRepositoryTests.swift",
        "DensosoTests/Application/GetMetricsToolTests.swift",
        "DensosoTests/Application/AgentToolOutputLimiterTests.swift",
        "DensosoTests/ConversationPersistenceTests.swift",
        "DensosoTests/Application/AgentRequestResumeTests.swift",
        "DensosoTests/Application/PromptInjectionEvalTests.swift",
        "DensosoTests/Application/AgentBudgetTests.swift",
        "DensosoTests/Application/ToolSchemaTests.swift",
        "DensosoTests/Application/GetRecentMealsToolTests.swift",
        "DensosoTests/Application/GetRecentWorkoutsToolTests.swift",
        "DensosoTests/Application/GetGoalToolTests.swift",
        "DensosoTests/Application/GetTodayPlanToolTests.swift",
        "DensosoTests/Application/DailyCheckInConfirmationTests.swift",
        "DensosoTests/Application/UserPreferenceConfirmationTests.swift",
        "DensosoTests/Application/GetUserPreferencesToolTests.swift",
        "DensosoTests/Application/DailyLoopSnapshotCompositionTests.swift",
        "DensosoTests/Application/ProviderUsageLedgerTests.swift",
        "DensosoTests/Presentation/RestrictedMarkdownRendererTests.swift",
        "DensosoTests/Privacy/ProviderLogRedactionTests.swift",
    ]
    for relative in test_files:
        if not (ROOT / relative).is_file():
            errors.append(f"missing {relative}")
    require_text(
        ROOT / "DensosoTests/Application/ProviderUsageLedgerTests.swift",
        [
            "testCachedInputUsesDescriptorPriceWithoutDoubleCounting",
            "testFractionalMicroCostsRoundUpForConservativeEstimate",
            "testPricingDescriptorRequiresExactModelAndCapability",
            "testMissingCachedPriceAndUnlistedVisionModelKeepCostUnknown",
            "testQwenSpeechUsageWithoutPricingDescriptorKeepsCostUnknown",
            "testUsageIdentityImageCountAndLatencyAreRetainedInLedgerSummary",
            "testUsageWithMismatchedRequestIdentityIsRejectedBeforePersistence",
            "testLegacyUsagePayloadDecodesWithUnknownImageAndLatencyMetadata",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests/Application/AgentTurnContractTests.swift",
        [
            "testLocalRecordSuggestionRemainsAProposalInsteadOfAStagedAction",
            "testCloudConfirmationActionsUseTheSameTypedTurnContract",
            "testTurnsWithoutActionsUseTheAnswerIntent",
            "testLocalFutureWorkoutIntentStaysDistinctFromCompletedWorkout",
            "testDomainIntentUsesClosedCodableContract",
            "testCaptureProposalCodableDoesNotPromoteItToAnAction",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests/LocalIntelligenceSuggestionTests.swift",
        ["testDoesNotTurnCompletedWorkoutOrUneatenMealIntoCaptureProposal"],
        errors,
    )

    fixture_paths = [
        ROOT / "DensosoTests/Fixtures/Gate03/Providers/DeepSeek/deepseek-responses-stream.sse",
        ROOT / "DensosoTests/Fixtures/Gate03/Providers/Qwen/qwen-text-tool-response.json",
        ROOT / "DensosoTests/Fixtures/Gate03/Providers/malformed.json",
    ]
    for path in fixture_paths:
        if not path.is_file():
            errors.append(f"missing {path.relative_to(ROOT)}")
        elif path.suffix == ".sse":
            event_types: set[str] = set()
            for line in read_text(path, errors).splitlines():
                if not line.startswith("data:"):
                    continue
                try:
                    event = json.loads(line.removeprefix("data:").strip())
                except json.JSONDecodeError as error:
                    errors.append(f"invalid DeepSeek SSE data in {path.relative_to(ROOT)}: {error}")
                    continue
                if isinstance(event, dict) and isinstance(event.get("type"), str):
                    event_types.add(event["type"])
            if not {"response.output_text.delta", "response.completed"}.issubset(event_types):
                errors.append("DeepSeek Responses fixture must cover text delta and completion events")
        else:
            try:
                json.loads(read_text(path, errors))
            except json.JSONDecodeError as error:
                errors.append(f"invalid JSON in {path.relative_to(ROOT)}: {error}")

    injection = ROOT / "evals" / "prompt-injection-phase3.yaml"
    injection_cases: list[dict[str, object]] = []
    if not injection.is_file():
        errors.append("missing evals/prompt-injection-phase3.yaml")
    else:
        try:
            injection_suite = json.loads(read_text(injection, errors))
        except (json.JSONDecodeError, OSError) as error:
            errors.append(f"prompt injection eval is not executable JSON/YAML: {error}")
        else:
            if injection_suite.get("version") != 1:
                errors.append("prompt injection eval version must be 1")
            raw_cases = injection_suite.get("cases")
            if not isinstance(raw_cases, list) or not raw_cases:
                errors.append("prompt injection eval must contain cases")
            else:
                injection_cases = raw_cases
                seen_ids: set[str] = set()
                for case in injection_cases:
                    if not isinstance(case, dict):
                        errors.append("prompt injection case must be an object")
                        continue
                    case_id = case.get("id")
                    scenario = case.get("scenario")
                    expected = case.get("expected")
                    if not isinstance(case_id, str) or not case_id or case_id in seen_ids:
                        errors.append("prompt injection case ids must be unique non-empty strings")
                    else:
                        seen_ids.add(case_id)
                    if scenario not in {"user_input", "tool_result"}:
                        errors.append(f"prompt injection case {case_id} has invalid scenario")
                    if not isinstance(case.get("input"), str) or not case["input"]:
                        errors.append(f"prompt injection case {case_id} has no input")
                    if not isinstance(expected, dict):
                        errors.append(f"prompt injection case {case_id} has no expected object")
                        continue
                    if expected.get("direct_health_writes") != 0:
                        errors.append(f"prompt injection case {case_id} permits a direct write")
                    if expected.get("pending_actions") != 1:
                        errors.append(f"prompt injection case {case_id} must require one pending action")
                    if expected.get("confirmation_required") is not True:
                        errors.append(f"prompt injection case {case_id} must require confirmation")

    require_text(
        ROOT / "project.yml",
        ["evals/prompt-injection-phase3.yaml", "buildPhase: resources"],
        errors,
    )

    require_text(
        ROOT / ".github" / "workflows" / "build.yml",
        [
            "agent-provider:", "needs: domain-persistence", "gate-03-agent-provider",
            "validate_phase3_agent_provider.py", "Gate03AgentProviderTests.xcresult",
            "gate-03-agent-provider-results",
            "-only-testing:DensosoTests/AgentReasoningPolicyTests",
            "-only-testing:DensosoTests/AgentTurnContractTests",
            "-only-testing:DensosoTests/LocalIntelligenceSuggestionTests",
            "-only-testing:DensosoTests/UserPreferenceConfirmationTests",
            "-only-testing:DensosoTests/GetUserPreferencesToolTests",
            "-only-testing:DensosoTests/GetTodayPlanToolTests",
            "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests",
            "-only-testing:DensosoTests/SwiftDataProviderGovernanceQueryTests",
            "-only-testing:DensosoTests/AgentDailyMetricsRepositoryTests",
            "-only-testing:DensosoTests/GetMetricsToolTests",
            "-only-testing:DensosoTests/AgentToolOutputLimiterTests",
            "-only-testing:DensosoTests/ConversationPersistenceTests",
        ],
        errors,
    )

    report = {
        "schemaVersion": 1,
        "gate": "gate-03-agent-provider-static-contracts",
        "status": "FAIL" if errors else "PASS",
        "failedAssertions": len(errors),
        "errors": errors,
        "providerFixtures": len(fixture_paths),
        "testFiles": len(test_files),
        "liveNetworkCalls": 0,
        "promptInjectionCases": len(injection_cases),
        "protectedOCRRead": False,
    }
    if args.report:
        report_path = Path(args.report)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("Phase 3 agent-provider static contracts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
