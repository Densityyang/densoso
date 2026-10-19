import DensosoDomain
import XCTest
@testable import Densoso

final class HealthNarrativePolicyTests: XCTestCase {
    func testStructuredNarrativeAcceptsOnlyKnownEvidenceKeysAndNarrativeText() throws {
        let allowed = Set(["sleep.mainSleep.minutes"])
        let valid = #"{"headline":"目前可按舒适节奏安排","summary":"现有证据支持继续留意规律作息。","recommendations":["保持稳定的日常节奏。"],"tomorrowGuidance":null,"evidenceKeys":["sleep.mainSleep.minutes"]}"#

        let decoded = try XCTUnwrap(HealthNarrativePolicy.decode(valid, allowedEvidenceKeys: allowed))
        XCTAssertEqual(decoded.evidenceKeys, ["sleep.mainSleep.minutes"])
        XCTAssertFalse(HealthNarrativePolicy.displayText(decoded).contains("sleep.mainSleep.minutes"))
    }

    func testNarrativeRejectsNumericMetricClaimsUnknownKeysAndExtraFields() {
        let allowed = Set(["sleep.mainSleep.minutes"])
        let numeric = #"{"headline":"状态下降 17%","summary":"目前可用证据支持留意休息。","recommendations":[],"tomorrowGuidance":null,"evidenceKeys":["sleep.mainSleep.minutes"]}"#
        let metric = #"{"headline":"HRV 需要留意","summary":"目前可用证据支持留意休息。","recommendations":[],"tomorrowGuidance":null,"evidenceKeys":["sleep.mainSleep.minutes"]}"#
        let unknownKey = #"{"headline":"状态需要留意","summary":"目前可用证据支持留意休息。","recommendations":[],"tomorrowGuidance":null,"evidenceKeys":["sleep.consistency"]}"#
        let extraField = #"{"headline":"状态需要留意","summary":"目前可用证据支持留意休息。","recommendations":[],"tomorrowGuidance":null,"evidenceKeys":["sleep.mainSleep.minutes"],"value":17}"#

        XCTAssertNil(HealthNarrativePolicy.decode(numeric, allowedEvidenceKeys: allowed))
        XCTAssertNil(HealthNarrativePolicy.decode(metric, allowedEvidenceKeys: allowed))
        XCTAssertNil(HealthNarrativePolicy.decode(unknownKey, allowedEvidenceKeys: allowed))
        XCTAssertNil(HealthNarrativePolicy.decode(extraField, allowedEvidenceKeys: allowed))
    }

    func testPromptUsesStructuredContractOnlyForPersonalHealthQuestions() throws {
        let context = makeContext()
        XCTAssertTrue(HealthContextPromptBuilder.requiresNarrative(for: "请分析我本周的睡眠趋势"))
        XCTAssertTrue(HealthContextPromptBuilder.requiresNarrative(for: "今天训练是否太多"))
        XCTAssertTrue(HealthContextPromptBuilder.requiresNarrative(for: "我最近很疲劳，应该休息吗？"))
        XCTAssertTrue(HealthContextPromptBuilder.requiresNarrative(for: "我的 HRV 如何？"))
        XCTAssertFalse(HealthContextPromptBuilder.requiresNarrative(for: "帮我记录体重 70kg"))
        XCTAssertFalse(HealthContextPromptBuilder.requiresNarrative(for: "帮我安排下周训练计划"))

        let prompt = HealthContextPromptBuilder.prompt(
            basePrompt: "base",
            userText: "请分析我本周的睡眠趋势",
            summary: context.aggregateSummary,
            narrativeContext: context,
            structuredNarrative: true
        )
        XCTAssertTrue(prompt.contains("健康解读结构（强制）"))
        XCTAssertTrue(prompt.contains("sleep.mainSleep.minutes"))
        XCTAssertTrue(prompt.contains("数值和指标由界面从本机确定性 HealthState 渲染"))

        let capturePrompt = HealthContextPromptBuilder.prompt(
            basePrompt: "base",
            userText: "帮我记录体重 70kg",
            summary: context.aggregateSummary,
            narrativeContext: context,
            structuredNarrative: true
        )
        XCTAssertFalse(capturePrompt.contains("健康解读结构（强制）"))
    }

    func testStructuredSchemaIsClosedAndConstrainsEvidenceKeys() {
        let format = HealthNarrativePolicy.responseFormat(allowedEvidenceKeys: ["sleep.mainSleep.minutes"])
        XCTAssertEqual(format.name, "health_narrative")
        guard case .object(let properties, let required, let additionalProperties, _) = format.schema else {
            return XCTFail("Expected closed JSON object schema")
        }
        XCTAssertFalse(additionalProperties)
        XCTAssertEqual(Set(required), Set(["headline", "summary", "recommendations", "tomorrowGuidance", "evidenceKeys"]))
        guard case .array(let items, _, _, _) = properties["evidenceKeys"] else {
            return XCTFail("Expected evidence key array")
        }
        guard case .string(let values, _, _, _, _) = items else {
            return XCTFail("Expected enumerated evidence key strings")
        }
        XCTAssertEqual(values, ["sleep.mainSleep.minutes"])
    }

    func testStateWithoutAggregateSummaryDoesNotProduceHealthConclusion() {
        let state = HealthStateV2(
            domains: [],
            recovery: RecoveryAssessment(
                status: .attention,
                confidence: .high,
                evidence: [EvidenceReference(key: "sleep.mainSleep.minutes", source: "sleep")],
                recommendedAction: .reduceIntensity
            ),
            trainingLoad: TrainingLoadSummary(
                recentSevenDayLoad: 0,
                priorTwentyEightDayAverage: nil,
                ratio: nil,
                readiness: .noData,
                band: .unavailable,
                estimatedWorkoutCount: 0,
                unavailableEffortCount: 0
            ),
            tomorrowGuidance: nil
        )
        let context = HealthNarrativeContext(
            healthState: state,
            evidence: state.recovery.evidence,
            recommendationCandidates: [],
            aggregateSummary: nil
        )

        let fallback = HealthNarrativePolicy.deterministicFallback(context)
        XCTAssertTrue(fallback.contains("没有可用的本地健康数据"))
        XCTAssertFalse(fallback.contains("恢复状态需要留意"))
    }

    private func makeContext() -> HealthNarrativeContext {
        let window = HealthContextWindowSummary(
            windowDays: 7,
            coverageDays: ["sleep": 5],
            averageSleepMinutes: 420,
            averageStepCount: nil,
            averageActiveEnergyKcal: nil,
            averageEnergyIntakeKcal: nil,
            averageDailyDeficitKcal: nil,
            averageProteinGrams: nil,
            medianWeightKilograms: nil
        )
        let summary = HealthContextSummary(
            sevenDay: window,
            twentyEightDay: HealthContextWindowSummary(
                windowDays: 28,
                coverageDays: ["sleep": 17],
                averageSleepMinutes: 415,
                averageStepCount: nil,
                averageActiveEnergyKcal: nil,
                averageEnergyIntakeKcal: nil,
                averageDailyDeficitKcal: nil,
                averageProteinGrams: nil,
                medianWeightKilograms: nil
            ),
            targetWeightKilograms: nil,
            dailyDeficitGoalKcal: nil,
            dailyProteinGoalGrams: nil,
            recommendationReferences: ["sleep.consistency", "sleep.mainSleep.minutes"]
        )
        let recommendation = HealthRecommendation(
            id: "sleep.consistency",
            domain: .sleep,
            title: "保持作息规律",
            detail: "尽量维持稳定的睡眠节奏。",
            evidenceKey: "sleep.mainSleep.minutes",
            conflictGroup: "sleep-routine",
            score: 0.8
        )
        return HealthNarrativeContext(
            healthState: nil,
            evidence: [EvidenceReference(key: "sleep.mainSleep.minutes", source: "sleep")],
            recommendationCandidates: [recommendation],
            aggregateSummary: summary
        )
    }
}
