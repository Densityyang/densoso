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


def require_text(path: Path, needles: list[str], errors: list[str]) -> None:
    if not path.is_file():
        errors.append(f"missing {path.relative_to(ROOT)}")
        return
    text = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle not in text:
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
        "Densoso/Application/Agent/AgentReasoningPolicy.swift",
        "Densoso/Application/Agent/AgentEvents.swift",
        "Densoso/Application/Agent/ToolSchemaValidator.swift",
        "Densoso/Application/Usage/ProviderUsageLedger.swift",
        "Densoso/Application/Formatting/AssistantBlock.swift",
        "Densoso/Application/Formatting/RestrictedMarkdownRenderer.swift",
        "Densoso/Views/Components/AssistantBlockView.swift",
        "Densoso/Agent/Tools/CreateWorkoutPlanTool.swift",
        "docs/gates/gate-03-agent-provider.md",
    ]
    for relative in required_files:
        if not (ROOT / relative).is_file():
            errors.append(f"missing {relative}")

    require_text(
        ROOT / "Densoso" / "Infrastructure" / "LLM" / "ProviderError.swift",
        [
            "configurationMissing", "consentRequired", "unauthorized", "rateLimited",
            "timeout", "network", "server", "malformedResponse", "contentRejected",
            "cancelled", "budgetExceeded",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "LLM" / "ProviderHTTPTransport.swift",
        ["maximumRetries: Int = 2", "Retry-After", "Task.checkCancellation", "deadline"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Infrastructure" / "LLM" / "DeepSeekProvider.swift",
        ["https://api.deepseek.com/responses", "deepseek-flash", "input_image", "response.output_text.delta"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Application" / "Agent" / "AgentReasoningPolicy.swift",
        ["forUserMessage", "return .high", "return .max"],
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
    agent_text = (ROOT / "Densoso" / "Agent" / "AgentSession.swift").read_text(encoding="utf-8")
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
            "AgentUserPreference(category:",
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
            "testOutputSizeLimitRemovesItemsAndReportsHasMore",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "DailyLoopSnapshotCompositionTests.swift",
        [
            "testComposerUsesMatchingExistingBriefAndPreservesOptionalState",
            "testComposerKeepsMissingMorningAndDaytimeSummariesNil",
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
            "agentSession.pendingActions",
            "workoutPlanSchedulingService.confirmedPlans()",
            "plansThroughTomorrow",
            "scheduledAt >= dayStart",
            "DailyLoopSnapshot(",
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
        ROOT / "Densoso" / "Infrastructure" / "Persistence" / "SwiftDataAgentRepository.swift",
        ["beginAgentRequest", "absoluteDeadline", "resumeCount", "containsTransientImage", "updateAgentRequestConsumption"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "AgentSession.swift",
        [
            "func send(multimodalRequest: MultimodalModelRequest",
            "containsTransientImage: multimodalRequest.image != nil || !multimodalRequest.mealEvidence.isEmpty",
            "transientMealImageEvidence = multimodalRequest.mealEvidence",
            "providerMessagesIncludingTransientMealEvidence()",
            "transientMealEvidenceMessage",
            "requestSnapshot.resumeCount > 0",
            "AgentError.transientImageRequired",
            "withoutTransientImages",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests" / "Application" / "AgentRequestResumeTests.swift",
        [
            "testInterruptedRequestResumesWithPersistedRemainingBudgetAndUsage",
            "testV4StoreMigratesToV5AndAddsAnEmptyRequestLedger",
            "resumeCount", "cachedInputTokens", "reasoningTokens",
            "containsTransientImage",
        ],
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
        ROOT / "DensosoTests" / "Application" / "GetGoalToolTests.swift",
        [
            "testToolUsesStrictEmptyReadOnlySchema",
            "testMissingOrEmptyGoalsReturnUnavailableWithoutDefaults",
            "testServiceReturnsOnlyCurrentEffectiveGoalAndReadDoesNotWrite",
        ],
        errors,
    )
    require_text(
        ROOT / "Packages" / "DensosoDomain" / "Sources" / "DensosoDomain" / "DailyCheckIn.swift",
        ["user-reported facts", "UserReportedEnergy", "UserReportedStress", "SubjectiveSleepQuality"],
        errors,
    )
    require_text(
        ROOT / "Densoso" / "Agent" / "Tools" / "StageDailyCheckInTool.swift",
        ["stage_daily_checkin", "ConfirmationRequiredTool", "UserReportedEnergy", "DailyCheckIn"],
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
    if "dishesJSON" in (ROOT / "Densoso" / "Agent" / "Tools" / "LogMealTool.swift").read_text(encoding="utf-8"):
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
            "registry.toolDefinitions.count, 19",
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
        "DensosoTests/Infrastructure/LLM/DeepSeekProviderContractTests.swift",
        "DensosoTests/Infrastructure/LLM/QwenProviderContractTests.swift",
        "DensosoTests/Infrastructure/LLM/ProviderRetryPolicyTests.swift",
        "DensosoTests/Application/AgentCoordinatorTests.swift",
        "DensosoTests/Application/AgentRequestResumeTests.swift",
        "DensosoTests/Application/PromptInjectionEvalTests.swift",
        "DensosoTests/Application/AgentBudgetTests.swift",
        "DensosoTests/Application/ToolSchemaTests.swift",
        "DensosoTests/Application/GetRecentMealsToolTests.swift",
        "DensosoTests/Application/GetRecentWorkoutsToolTests.swift",
        "DensosoTests/Application/GetGoalToolTests.swift",
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
            for line in path.read_text(encoding="utf-8").splitlines():
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
            json.loads(path.read_text(encoding="utf-8"))

    injection = ROOT / "evals" / "prompt-injection-phase3.yaml"
    injection_cases: list[dict[str, object]] = []
    if not injection.is_file():
        errors.append("missing evals/prompt-injection-phase3.yaml")
    else:
        try:
            injection_suite = json.loads(injection.read_text(encoding="utf-8"))
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
            "-only-testing:DensosoTests/UserPreferenceConfirmationTests",
            "-only-testing:DensosoTests/GetUserPreferencesToolTests",
            "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests",
        ],
        errors,
    )

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    report = {
        "status": "pass",
        "providerFixtures": len(fixture_paths),
        "testFiles": len(test_files),
        "liveNetworkCalls": 0,
        "promptInjectionCases": len(injection_cases),
        "protectedOCRRead": False,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    print("Phase 3 agent-provider static contracts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
