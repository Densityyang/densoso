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
            "private static let formatVersion = 4",
            "private static let supportedFormatVersions: Set<Int> = [2, 3, 4]",
            "weightRecords: [WeightRecordExport]?",
            "goalProfiles: [GoalProfileExport]?",
            "dailyHealthSnapshots: [DailyHealthSnapshotExport]?",
            "scheduleEvents: [ScheduleEventExport]?",
            "dailyBriefs: [DailyBriefExport]?",
            "weeklyBriefs: [WeeklyBriefExport]?",
            "weeklyReports: [WeeklyReportExport]?",
            "HealthSyncOutboxEntry.self",
            "HealthKitImportCursor.self",
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
            "testV4BackupRestoresHealthDataGoalsAndReportsWithoutSyncQueueState",
            "XCTAssertEqual(exported.formatVersion, 4)",
        ),
        errors,
    )
    screenshot_tests = require_text(
        "DensosoUITests/Gate09IntegrationScreenshotsTests.swift",
        (
            "testAllPrimaryTabsCapturePortraitScreensWithAccessibilityLabels",
            "testPrimaryTabsRemainReachableWithLargeTextAndDarkAppearance",
            'keepScreenshot(named: "gate-09-',
            "let appFrame = app.windows.firstMatch.frame",
            "XCTAssertGreaterThan(appFrame.height, appFrame.width)",
        ),
        errors,
    )
    if "XCUIScreen.main.bounds" in screenshot_tests:
        errors.append("UI portrait screenshots must use supported XCUIApplication frame APIs")
    require_text(
        "DensosoUITests/Fixtures/Gate01/expected-tabs.json",
        ('"tab": "今天"', '"tab": "趋势"', '"tab": "记录"', '"tab": "设置"'),
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
            "format version 4",
            "Gates 1–8",
            "physical iPhone render",
            "blocked-by-signing",
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
        "scope": "four-tab-integration-and-v4-backup",
        "backupCompatibility": [2, 3, 4],
        "sensitiveSyncStateRestored": False,
        "physicalDeviceVisualAcceptanceClaimed": False,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Phase 9 integration static contracts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
