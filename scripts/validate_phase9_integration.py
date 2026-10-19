#!/usr/bin/env python3
"""Validate Phase 9 integration, backup compatibility and evidence contracts."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require_text(relative: str, needles: tuple[str, ...], errors: list[str]) -> str:
    path = ROOT / relative
    if not path.is_file():
        errors.append(f"missing {relative}")
        return ""
    text = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle not in text:
            errors.append(f"{relative} is missing {needle}")
    return text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report")
    args = parser.parse_args()
    errors: list[str] = []

    tabs = require_text(
        "Densoso/Views/ContentView.swift",
        (
            'Label("今天"',
            'Label("趋势"',
            'Label("记录"',
            'Label("设置"',
            "struct MainTabView",
        ),
        errors,
    )
    if 'Label("计划"' in tabs or 'Label("历史"' in tabs:
        errors.append("the final app navigation must use only Today/Trends/Records/Settings")

    export = require_text(
        "Densoso/Services/ExportService.swift",
        (
            "private static let formatVersion = 5",
            "private static let supportedFormatVersions: Set<Int> = [2, 3, 4, 5]",
            "weightRecords: [WeightRecordExport]?",
            "goalProfiles: [GoalProfileExport]?",
            "dailyHealthSnapshots: [DailyHealthSnapshotExport]?",
            "scheduleEvents: [ScheduleEventExport]?",
            "dailyBriefs: [DailyBriefExport]?",
            "weeklyBriefs: [WeeklyBriefExport]?",
            "weeklyReports: [WeeklyReportExport]?",
            "dailyCheckIns: [DailyCheckInExport]?",
            "userPreferences: [UserPreferenceExport]?",
            "DailyCheckInRecord.self",
            "UserPreferenceRecord.self",
            "unfinishedRequestIDs",
            "AgentRequestRecord",
            "HealthSyncOutboxEntry.self",
            "HealthKitImportCursor.self",
            "private static let backupReadBatchSize = 64",
            "private func fetchAllRecords<Record: PersistentModel>(",
            "descriptor.fetchLimit = Self.backupReadBatchSize",
            "descriptor.fetchOffset = offset",
            "let requestRecords = try fetchAllRecords(",
            "of: AgentRequestRecord.self",
            "of: MessageRecord.self",
        ),
        errors,
    )
    if "credentials" in export.lower() or "consentrecord" in export.lower():
        errors.append("active credentials and provider consent must not be included in backups")

    require_text(
        "DensosoTests/ExportServiceTests.swift",
        (
            "testLegacyV2BackupStillRestoresAfterGate5EvidenceFieldsWereAdded",
            "testLegacyV3BackupStillRestoresMealEvidenceAfterHealthDataWasAdded",
            "testV5BackupRestoresProfileHistoryAndHealthDataWithoutSyncQueueState",
            "exported.payload.dailyCheckIns?.count",
            "summary.dailyCheckIns",
            "exported.payload.userPreferences?.count",
            "summary.userPreferences",
            "未确认的偏好",
            "not-part-of-backup",
            "XCTAssertEqual(exported.formatVersion, 5)",
            "energyIntakeKcal: try EstimateRange(low: 450, likely: 500, high: 600)",
            "testBackupExportPagesMealHistoryAcross64RowBoundary",
            "testRestorePagesInterruptedRequestHistoryAcross64RowBoundary",
        ),
        errors,
    )
    history_screen = require_text(
        "Densoso/Views/HistoryScreen.swift",
        (
            "HistoryRecordPageReader",
            ".refreshable { reload() }",
            "NotificationCenter.default.publisher(for: ModelContext.didSave)",
            ".receive(on: DispatchQueue.main)",
            "handleModelContextSave(notification)",
            "changedEntityNames.formUnion(identifiers.map(\\.entityName))",
            ".invalidatedAllIdentifiers",
            "shouldRefreshSelectedRecordsFromNewest",
            "potentiallyNewRecordKeys",
            "potentiallyNewEntityNames.contains(selectedEntity)",
            "@State private var hasNewerRecords = false",
            "if hasNewerRecords",
            "Button(\"记录已更新，刷新列表\") { reloadSelectedRecords() }",
            "hasNewerRecords = false",
            "hasNewerRecords = true",
            "pageReader.syncSummary(in: modelContext)",
            "pageReader.meals(in: modelContext, during: selectedDateRange)",
            "pageReader.workouts(in: modelContext, during: selectedDateRange)",
            "pageReader.weights(in: modelContext, during: selectedDateRange)",
            "Button(\"加载更早餐食\")",
            "Button(\"加载更早运动\")",
            "Button(\"加载更早体重\")",
        ),
        errors,
    )
    if "@Query" in history_screen:
        errors.append("Records history must not materialize all record kinds through @Query")
    require_text(
        "Densoso/Services/HistoryRecordPageReader.swift",
        (
            "static let pageSize = 64",
            "func meals(",
            "func workouts(",
            "func weights(",
            "descriptor.fetchLimit = Self.pageSize",
            "lookAhead.fetchLimit = 1",
            "context.fetchCount(FetchDescriptor(predicate: pendingPredicate))",
            "context.fetchCount(FetchDescriptor(predicate: failedPredicate))",
            "cursorDescriptor.fetchLimit = 1",
        ),
        errors,
    )
    require_text(
        "DensosoTests/HistoryRecordPageReaderTests.swift",
        (
            "testRecordHistoryPagesByDayAndKeepsOlderRowsReachable",
            "testSyncSummaryCountsOutboxStatesAndFindsLatestImportWithoutLoadingRows",
        ),
        errors,
    )
    screenshot_tests = require_text(
        "DensosoUITests/Gate09IntegrationScreenshotsTests.swift",
        (
            "testAllPrimaryTabsCapturePortraitScreensWithAccessibilityLabels",
            "testVoiceBarPrioritizesVoiceAndOpensEditableTextEntry",
            "testPrimaryTabsRemainReachableWithLargeTextAndDarkAppearance",
            "daily-loop-snapshot",
            "daily-loop-phase",
            'keepScreenshot(named: "gate-09-',
            "let appFrame = app.windows.firstMatch.frame",
            "XCTAssertGreaterThan(appFrame.height, appFrame.width)",
        ),
        errors,
    )
    if "XCUIScreen.main.bounds" in screenshot_tests:
        errors.append("UI portrait screenshots must use supported XCUIApplication frame APIs")
    chat_screen = require_text(
        "Densoso/Views/ChatScreen.swift",
        (
            "DailyLoopSnapshotCard(snapshot: dailyLoopSnapshot)",
            "dailyLoopSnapshotService.snapshot()",
            "开始说话",
            "停止录音",
            "照片记餐",
            "today-voice-primary",
            "today-photo-secondary",
            "today-text-entry",
            "today-composer",
            "today-send",
            "发送",
        ),
        errors,
    )
    quick_action_handler = chat_screen.split("private func promptButton(for action:", 1)[-1].split(
        "private func quickActionDetails", 1
    )[0]
    if "send(" in quick_action_handler or "agentSession" in quick_action_handler:
        errors.append("Today quick actions must only prefill the editable composer")
    require_text(
        "Densoso/App/Dependencies.swift",
        ("dailyLoopSnapshotService: DailyLoopSnapshotService", "DailyLoopSnapshotService("),
        errors,
    )
    daily_loop = require_text(
        "Densoso/Application/DailyLoop/DailyLoopSnapshotService.swift",
        (
            "healthIntelligenceService.dailyBrief",
            "agentSession.pendingActions",
            "workoutPlanSchedulingService.confirmedPlans()",
            "plansThroughTomorrow",
            "scheduledAt >= dayStart",
            "DailyLoopSnapshot(",
        ),
        errors,
    )
    if "healthIntelligenceService.refresh()" in daily_loop or "todayHealthState(" in daily_loop:
        errors.append("DailyLoop composition must not refresh or recalculate health state")
    require_text(
        "Densoso/Views/Components/DailyLoopSnapshotCard.swift",
        (
            "daily-loop-snapshot",
            "daily-loop-phase",
            "todayState",
            "todaySummary",
            "tomorrowGuidance",
            "pendingActions",
            "workoutPlans",
            "今日状态暂不可用",
        ),
        errors,
    )
    intent_source = require_text(
        "Densoso/Intents/DensosoAppShortcuts.swift",
        (
            "struct ViewTodayStatusIntent",
            "struct ViewTodayGuidanceIntent",
            "struct OpenDensosoIntent",
            "struct StartRecordIntent",
            "struct StartWorkoutIntent",
            "struct CreateWorkoutPlanIntent",
            "struct LogMealByVoiceIntent",
            "intent: ViewTodayStatusIntent()",
            "intent: ViewTodayGuidanceIntent()",
            "intent: OpenDensosoIntent()",
            "intent: StartRecordIntent()",
            "openAppWhenRun = true",
            "store(destination:",
            "store(workoutPlan:",
            "store(mealText:",
            "consumeDestination",
        ),
        errors,
    )
    if "ModelContext" in intent_source or "HKHealthStore" in intent_source:
        errors.append("App Intents must hand off a request without writing SwiftData or HealthKit")
    require_text(
        "Densoso/App/AppState.swift",
        ("pendingSystemIntent", "shouldFocusComposer", "shouldScrollToDailyLoop"),
        errors,
    )
    require_text(
        "Densoso/App/DensosoApp.swift",
        ("AppIntentInbox.consumeDestination()", "appState.pendingSystemIntent"),
        errors,
    )
    require_text(
        "Densoso/Views/ContentView.swift",
        (
            "selectedTab = 0",
            "consumeSystemIntent",
            "AppIntentInbox.consumeDestination()",
            "case .startRecording",
            "shouldFocusComposer = true",
        ),
        errors,
    )
    require_text(
        "Densoso/Views/ChatScreen.swift",
        (".focused($composerFocused)", "appState.shouldFocusComposer", "scrollTo(\"daily-loop-snapshot-anchor\""),
        errors,
    )
    require_text(
        "DensosoTests/Application/AppIntentInboxTests.swift",
        ("testSystemDestinationsRoundTripAndAreConsumedOnce", "startRecording"),
        errors,
    )
    diagnostics_service = require_text(
        "Densoso/Services/DiagnosticsExportService.swift",
        (
            "struct DiagnosticsExportDocument",
            "struct DiagnosticsDailyLoopStatus",
            "struct DiagnosticsImportCursorStatus",
            "lastGeneratedAt",
            "nextRefreshEarliestAt",
            "importCursors: [DiagnosticsImportCursorStatus]",
            "safeHealthStream(cursor.stream)",
            "ProviderUsageRecord",
            "HealthSyncOutboxEntry",
            "HealthKitImportCursor",
            "DailyMetrics",
            "ProviderLogBuffer",
            "completeFileProtection",
        ),
        errors,
    )
    for forbidden in (
        "MealRecord",
        "WeightRecord",
        "MessageRecord",
        "UserPreferenceRecord",
        "DailyCheckInRecord",
        "ConsentRecord",
        "KeychainStore",
        "APIKey",
        "payloadData",
        "lastError",
        "anchorData",
        "sourceFingerprint",
        "dataCoverageJSON",
    ):
        if forbidden in diagnostics_service:
            errors.append(f"diagnostics export source must not access {forbidden}")
    require_text(
        "Densoso/Infrastructure/LLM/ProviderLogRedactor.swift",
        (
            "struct ProviderLogMetadata",
            "static func safeModel",
            "static func safeProviderCode",
            "static func errorCode(for error: Error)",
            "final class ProviderLogBuffer",
            "private let capacity: Int",
        ),
        errors,
    )
    require_text(
        "Densoso/Services/IntelligenceRouting.swift",
        ("private let logSink: any ProviderLogSink", "logSink: logSink"),
        errors,
    )
    require_text(
        "Densoso/Views/SettingsScreen.swift",
        (
            'Button("导出系统诊断 JSON"',
            "diagnosticsExportService.exportJSON(",
            "hasError: watch.lastError != nil",
            "dailyLoop: DiagnosticsDailyLoopStatus(",
            "不含健康记录、备注、转录、偏好、密钥或同意内容",
        ),
        errors,
    )
    require_text(
        "DensosoTests/Privacy/DiagnosticsExportPrivacyTests.swift",
        (
            "testExportContainsOnlyWhitelistedDiagnosticsAndIsReadOnly",
            "testProviderLogBufferIsBoundedAndRedactsModelAndErrorCode",
            "testProviderErrorsExportOnlyAllowlistedCodes",
            "PRIVATE-USER-DATA-DO-NOT-EXPORT",
            "sk-private-api-key-do-not-export",
            "PRIVATE-TRANSCRIPT",
            "PRIVATE-HEALTH-SAMPLE",
            "PRIVATE-DRAFT-NOTE",
            "PRIVATE-PREFERENCE",
            "PRIVATE-CONSENT",
            "sourceFingerprint",
            "XCTAssertEqual(before, after)",
        ),
        errors,
    )
    require_text(
        "DensosoUITests/Gate09IntegrationScreenshotsTests.swift",
        (
            "testTodayQuickActionPrefillsEditableComposerWithoutSubmitting",
            "记录体重",
            "today-composer",
            "正在整理草稿",
        ),
        errors,
    )
    require_text(
        "Densoso/Views/ChatScreen.swift",
        (
            r"ForEach(dailyLoopSnapshot?.quickActions ?? [], id: \.rawValue)",
            "case .logWeight",
            "case .dailyCheckIn",
            "inputText = details.prompt",
        ),
        errors,
    )
    require_text(
        "DensosoUITests/Fixtures/Gate01/expected-tabs.json",
        ('"tab": "今天"', '"tab": "趋势"', '"tab": "记录"', '"tab": "设置"'),
        errors,
    )
    require_text(
        "DensosoTests/Application/DailyLoopSnapshotCompositionTests.swift",
        ("stale-plan", "distant-plan", "tomorrowPlan.actionID"),
        errors,
    )
    require_text(
        "DensosoTests/Application/AppIntentInboxTests.swift",
        ("testSystemDestinationsRoundTripAndAreConsumedOnce", "todayGuidance", "startRecording"),
        errors,
    )
    require_text(
        "DensosoTests/Application/AgentCoordinatorTests.swift",
        (
            "testOfflineWatchTranscriptSurvivesFailureResumesSameDraftAndConfirmsOnce",
            "testCloudProviderRequiresExplicitConsent",
            "testRealRoundAndToolCountsAndPendingAction",
        ),
        errors,
    )
    require_text(
        "DensosoTests/Application/SpeechCaptureStateMachineTests.swift",
        ("testSuccessfulCaptureUsesOneTapAndSupportsRepeatedStartStop",),
        errors,
    )
    require_text(
        "DensosoTests/HealthKitSyncCoordinatorTests.swift",
        ("testObserverCompletionRunsAfterAnchoredWorkoutIsCommitted", "onObserverSyncCompleted"),
        errors,
    )
    require_text(
        "DensosoTests/HealthIntelligenceServiceTests.swift",
        ("testPreviousWeekUsesItsFullTwentyEightDayBaselineOnSunday",),
        errors,
    )
    require_text(
        "DensosoTests/Application/MealCaptureApplicationServiceTests.swift",
        (
            "testBarcodeMatchSkipsQwenAndStillCreatesOnlyPendingAction",
            "testPrepareForAgentRoutesResolvedBarcodeLocallyAndStagesPendingAction",
            "testPrepareForAgentKeepsCompleteLabelLocalAndAsksOnceForMissingPortion",
            "testPrepareForAgentUsesTextFallbackForBarcodeMissAndImageOnlyForOpenPhoto",
            "testLocalMealPortionAnswerSupportsCountsAndRejectsPackageSpecsAsConsumedAmount",
            "testOpenPhotoRequiresSeparateImageConsent",
            "testPortionClarificationMustBeAnsweredAndIsPersistedAsUserEvidence",
        ),
        errors,
    )
    require_text(
        "DensosoTests/ConfirmationCoordinatorTests.swift",
        ("testMealConfirmationPreservesMeasuredHealthKitEnergyProjection", "testConcurrentStageAndConfirmWriteOneLogicalTransaction"),
        errors,
    )
    require_text(
        "DensosoTests/HealthSyncOutboxWorkerTests.swift",
        ("testConfirmedMealWritesOnlyKnownNutritionAndPersistsReceipt",),
        errors,
    )
    require_text(
        "DensosoTests/Presentation/RestrictedMarkdownRendererTests.swift",
        ("testUnbalancedMarkdownFallsBackWithoutRawAsterisks",),
        errors,
    )
    require_text(
        "DensosoTests/IntelligenceRoutingPolicyTests.swift",
        ("testLocalOnlyFallsBackToManualWhenModelUnavailable", "testCloudRequiresExplicitCloudMode", "testPhase3QwenEnablesTextButNotVisionOrSpeech"),
        errors,
    )
    require_text(
        "DensosoTests/Infrastructure/LLM/DeepSeekProviderContractTests.swift",
        ("testMissingKeyFailsBeforeNetworkOrUserContentIsSent",),
        errors,
    )
    require_text(
        "docs/gates/gate-09-integration.md",
        (
            "Status:",
            "format version 5",
            "Gates 1–8",
            "physical iPhone render",
            "blocked-by-signing",
            "Privacy-focused diagnostics export",
            "DiagnosticsExportPrivacyTests",
            "Export reads every collection in ordered 64-row SwiftData pages",
            "Restore likewise pages request/message history in batches",
            "Records history queries only the selected record kind and optional day",
            "while preserving the current page, it shows a \"记录已更新，刷新列表\" action",
            "after model-context saves and supports pull-to-refresh",
        ),
        errors,
    )
    workflow = require_text(
        ".github/workflows/build.yml",
        (
            "integration:",
            "name: gate-09-integration",
            "needs: watch",
            "-only-testing:DensosoTests",
            "-only-testing:DensosoUITests",
            "Gate09IntegrationTests.xcresult",
            "Gate09UITests.xcresult",
            "gate-09-integration-results",
        ),
        errors,
    )
    if "xcov" not in workflow.lower() and "xccov view --report" not in workflow:
        errors.append("Gate 9 must export a coverage summary")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    report = {
        "status": "pass",
        "scope": "four-tab-integration-v5-backup-and-privacy-focused-diagnostics-export",
        "backupCompatibility": [2, 3, 4, 5],
        "userReportedCheckInsExported": True,
        "userReportedPreferencesExported": True,
        "dailyLoopTodaySurfaceIntegrated": True,
        "diagnosticsExportWhitelistRequired": True,
        "unfinishedAgentRequestsRestored": False,
        "sensitiveSyncStateRestored": False,
        "physicalDeviceVisualAcceptanceClaimed": False,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Phase 9 integration static contracts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
