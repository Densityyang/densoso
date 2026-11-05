import DensosoDomain
import XCTest
@testable import Densoso

final class HealthContextPromptBuilderTests: XCTestCase {
    func testOrdinaryQuestionsDoNotLoadPersonalHealthContext() {
        XCTAssertFalse(HealthContextPromptBuilder.shouldIncludeSummary(for: "今天天气怎么样？"))
        XCTAssertFalse(HealthContextPromptBuilder.requiresNarrative(for: "今天有什么好玩的？"))
        XCTAssertFalse(HealthContextPromptBuilder.shouldIncludeSummary(for: "How do I format a date?"))
    }

    func testSleepAnalysisLoadsHealthContext() {
        XCTAssertTrue(HealthContextPromptBuilder.shouldIncludeSummary(for: "分析一下我的睡眠"))
        XCTAssertTrue(HealthContextPromptBuilder.requiresNarrative(for: "分析一下我的睡眠"))
    }

    func testMealEstimationLoadsRelevantContextWithoutNarrativeWorkflow() {
        let request = "帮我估算午餐热量和蛋白质"
        XCTAssertTrue(HealthContextPromptBuilder.shouldIncludeSummary(for: request))
        XCTAssertFalse(HealthContextPromptBuilder.requiresNarrative(for: request))
        XCTAssertTrue(HealthContextPromptBuilder.requiresMealEstimationContext(for: request))
        XCTAssertFalse(HealthContextPromptBuilder.requiresMealEstimationContext(for: "记录午餐：米饭和鸡肉"))
        XCTAssertFalse(HealthContextPromptBuilder.requiresMealEstimationContext(for: "估算跑步消耗热量"))
        XCTAssertTrue(HealthContextPromptBuilder.requiresMealEstimationContext(for: "Estimate macros"))
    }

    func testBodyMetricInterpretationLoadsHealthContext() {
        XCTAssertTrue(HealthContextPromptBuilder.shouldIncludeSummary(for: "帮我解读一下体重和静息心率变化"))
        XCTAssertTrue(HealthContextPromptBuilder.requiresNarrative(for: "帮我解读一下体重和静息心率变化"))
    }

    func testVitalIntentTermsMatchOnlyMetricsAvailableInHealthContext() {
        let supportedRequests = [
            "分析我的体重趋势",
            "分析我的静息心率趋势",
            "分析我的心率变异趋势",
            "分析我的呼吸频率趋势",
            "分析我的腕温趋势",
            "Analyze my resting heart rate trend",
            "Analyze my heart rate variability trend",
            "Analyze my respiratory rate trend",
            "Analyze my wrist temperature trend",
        ]
        for request in supportedRequests {
            XCTAssertTrue(HealthContextPromptBuilder.shouldIncludeSummary(for: request), request)
            XCTAssertTrue(HealthContextPromptBuilder.requiresNarrative(for: request), request)
        }

        let unsupportedRequests = [
            "分析我的身高变化",
            "分析我的体脂变化",
            "分析我的腰围变化",
            "分析我的血压变化",
            "分析我的血糖变化",
            "分析我的BMI变化",
            "分析我的心率变化",
            "Analyze my height trend",
            "Analyze my body fat trend",
            "Analyze my blood pressure trend",
            "Analyze my blood sugar trend",
            "Analyze my BMI trend",
            "Analyze my heart rate trend",
        ]
        for request in unsupportedRequests {
            XCTAssertFalse(HealthContextPromptBuilder.shouldIncludeSummary(for: request), request)
            XCTAssertFalse(HealthContextPromptBuilder.requiresNarrative(for: request), request)
        }
    }

    func testExerciseRecoveryLoadsHealthContext() {
        let request = "昨天跑完步以后腿很酸，今天怎么恢复？"
        XCTAssertTrue(HealthContextPromptBuilder.shouldIncludeSummary(for: request))
        XCTAssertTrue(HealthContextPromptBuilder.requiresNarrative(for: request))
    }

    func testHealthFollowUpUsesPriorConversationContext() {
        XCTAssertFalse(HealthContextPromptBuilder.shouldIncludeSummary(for: "那我今天呢？"))
        XCTAssertTrue(HealthContextPromptBuilder.shouldIncludeSummary(
            for: "那我今天呢？",
            priorHealthContext: true
        ))
        XCTAssertTrue(HealthContextPromptBuilder.requiresNarrative(
            for: "那我今天呢？",
            priorHealthContext: true
        ))
    }

    func testHealthContextFollowUpPersistsAcrossMultipleShortTurns() {
        let priorUserMessages = ["分析一下我的睡眠", "那我今天呢？"]
        let priorHealthContext = HealthContextPromptBuilder.hasPriorHealthContext(
            in: priorUserMessages
        )

        XCTAssertTrue(priorHealthContext)
        XCTAssertTrue(HealthContextPromptBuilder.shouldIncludeSummary(
            for: "那明天呢？",
            priorHealthContext: priorHealthContext
        ))
        XCTAssertFalse(HealthContextPromptBuilder.hasPriorHealthContext(in: [
            "分析一下我的睡眠",
            "换个话题，推荐一部电影。",
            "那我今天呢？",
        ]))
    }

    func testColloquialSleepAndFoodQuestionsLoadRelevantContext() {
        XCTAssertTrue(HealthContextPromptBuilder.shouldIncludeSummary(for: "我最近睡不好，怎么调整？"))
        XCTAssertTrue(HealthContextPromptBuilder.requiresNarrative(for: "我最近睡不好，怎么调整？"))
        XCTAssertTrue(HealthContextPromptBuilder.shouldIncludeSummary(for: "今天我吃了什么？"))
        XCTAssertFalse(HealthContextPromptBuilder.requiresNarrative(for: "今天我吃了什么？"))
    }

    func testSimplePersonalMetricReadLoadsContextWithoutStructuredNarrative() {
        let request = "我的活动量记录"
        XCTAssertTrue(HealthContextPromptBuilder.shouldIncludeSummary(for: request))
        XCTAssertFalse(HealthContextPromptBuilder.requiresNarrative(for: request))
        XCTAssertTrue(HealthContextPromptBuilder.requiresHealthContext(for: request))
        XCTAssertFalse(HealthContextPromptBuilder.requiresHealthContext(for: "记录体重 62.5 公斤"))
        XCTAssertFalse(HealthContextPromptBuilder.requiresHealthContext(for: "今天天气怎么样？"))
    }

    func testColloquialTranscribedHealthQuestionLoadsContext() {
        let transcript = "我昨晚老醒，今天还适合去跑步吗"
        XCTAssertTrue(HealthContextPromptBuilder.shouldIncludeSummary(for: transcript))
        XCTAssertTrue(HealthContextPromptBuilder.requiresNarrative(for: transcript))
    }

    func testAggregatedHealthContextIsOnlyAttachedToRelevantCloudQuestions() throws {
        let seven = HealthContextWindowSummary(
            windowDays: 7,
            coverageDays: ["sleep": 5, "bodyMass": 3],
            averageSleepMinutes: 420,
            averageStepCount: 7_000,
            averageActiveEnergyKcal: 400,
            averageEnergyIntakeKcal: 1_900,
            averageDailyDeficitKcal: 300,
            averageProteinGrams: 90,
            medianWeightKilograms: 70.2
        )
        let twentyEight = HealthContextWindowSummary(
            windowDays: 28,
            coverageDays: ["sleep": 18, "bodyMass": 12],
            averageSleepMinutes: 415,
            averageStepCount: 6_800,
            averageActiveEnergyKcal: 390,
            averageEnergyIntakeKcal: 1_950,
            averageDailyDeficitKcal: 260,
            averageProteinGrams: 88,
            medianWeightKilograms: 70.5
        )
        let summary = HealthContextSummary(
            sevenDay: seven,
            twentyEightDay: twentyEight,
            targetWeightKilograms: 68,
            dailyDeficitGoalKcal: 350,
            dailyProteinGoalGrams: 100,
            recommendationReferences: ["sleep.consistency", "sleep.mainSleep.minutes"]
        )

        let base = "base prompt"
        XCTAssertEqual(HealthContextPromptBuilder.prompt(basePrompt: base, userText: "你好", summary: summary), base)
        let healthPrompt = HealthContextPromptBuilder.prompt(
            basePrompt: base,
            userText: "请分析我本周的睡眠和体重趋势",
            summary: summary
        )
        XCTAssertTrue(healthPrompt.contains("sevenDay"))
        XCTAssertTrue(healthPrompt.contains("twentyEightDay"))
        XCTAssertTrue(healthPrompt.contains("sleep.mainSleep.minutes"))
        XCTAssertFalse(healthPrompt.contains("healthKitSamples"))
        XCTAssertFalse(healthPrompt.contains("startDate"))
    }

    func testStructuredNarrativeDoesNotDuplicateAggregateSummary() throws {
        let summary = HealthContextSummary(
            sevenDay: HealthContextWindowSummary(
                windowDays: 7,
                coverageDays: ["sleep": 5],
                averageSleepMinutes: 617,
                averageStepCount: nil,
                averageActiveEnergyKcal: nil,
                averageEnergyIntakeKcal: nil,
                averageDailyDeficitKcal: nil,
                averageProteinGrams: nil,
                medianWeightKilograms: nil
            ),
            twentyEightDay: HealthContextWindowSummary(
                windowDays: 28,
                coverageDays: ["sleep": 20],
                averageSleepMinutes: 611,
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
            recommendationReferences: []
        )
        let baseline = HealthBaseline(
            readiness: .mature,
            validDays: 28,
            median: 55,
            p10: 50,
            p90: 60,
            mad: 2
        )
        let cloudHealthState = CloudHealthStateContext(domains: [
            HealthDomainResult(
                domain: .body,
                status: .withinTypicalRange,
                currentValue: 70,
                baseline: baseline,
                evidenceKeys: ["body.weight.kg"]
            ),
        ])
        let context = HealthNarrativeContext(
            healthState: nil,
            evidence: [EvidenceReference(key: "sleep.mainSleep.minutes", source: "sleep")],
            recommendationCandidates: [],
            aggregateSummary: summary,
            vitalTrends: [HealthVitalTrend(
                metric: .restingHeartRate,
                latestMedian: 57,
                baseline: baseline,
                status: .withinTypicalRange,
                evidenceKey: "vitals.restingHeartRate.median",
                dataCoverage: .complete
            )],
            activityTrends: [ActivityMetricTrend(
                metric: .steps,
                currentValue: 6_200,
                baselineWindowDays: 28,
                baseline: baseline,
                status: .withinTypicalRange,
                dataCoverage: .complete
            )],
            cloudHealthState: cloudHealthState
        )

        let prompt = HealthContextPromptBuilder.prompt(
            basePrompt: "base",
            userText: "分析我的睡眠",
            summary: summary,
            narrativeContext: context,
            structuredNarrative: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encodedSummary = String(data: try encoder.encode(summary), encoding: .utf8)!

        XCTAssertEqual(prompt.components(separatedBy: encodedSummary).count - 1, 1)
        XCTAssertTrue(prompt.contains("cloudHealthState"))
        XCTAssertTrue(prompt.contains("vitalTrends"))
        XCTAssertTrue(prompt.contains("activityTrends"))
        XCTAssertTrue(prompt.contains("vitals.restingHeartRate.median"))
        XCTAssertFalse(prompt.contains("\"healthState\""))
    }

    func testMealEstimationPromptNeverFallsBackToFullHealthSummary() {
        let summary = HealthContextSummary(
            sevenDay: HealthContextWindowSummary(
                windowDays: 7,
                coverageDays: ["sleep": 6],
                averageSleepMinutes: 617,
                averageStepCount: nil,
                averageActiveEnergyKcal: nil,
                averageEnergyIntakeKcal: 2_111,
                averageDailyDeficitKcal: nil,
                averageProteinGrams: 81,
                medianWeightKilograms: nil
            ),
            twentyEightDay: HealthContextWindowSummary(
                windowDays: 28,
                coverageDays: ["sleep": 20],
                averageSleepMinutes: 611,
                averageStepCount: nil,
                averageActiveEnergyKcal: nil,
                averageEnergyIntakeKcal: 2_080,
                averageDailyDeficitKcal: nil,
                averageProteinGrams: 79,
                medianWeightKilograms: nil
            ),
            targetWeightKilograms: nil,
            dailyDeficitGoalKcal: nil,
            dailyProteinGoalGrams: 92,
            recommendationReferences: []
        )

        let withoutNutritionContext = HealthContextPromptBuilder.prompt(
            basePrompt: "base",
            userText: "Estimate macros",
            summary: summary
        )
        XCTAssertEqual(withoutNutritionContext, "base")

        let nutritionContext = MealEstimationNutritionContext(
            today: nil,
            sevenDay: nil,
            twentyEightDay: nil,
            analysisWindowCoverage: [:],
            dailyProteinGoalGrams: 92,
            evidenceKeys: []
        )
        let withNutritionContext = HealthContextPromptBuilder.prompt(
            basePrompt: "base",
            userText: "Estimate macros",
            summary: summary,
            mealEstimationNutritionContext: nutritionContext
        )
        XCTAssertTrue(withNutritionContext.contains("餐食估算的本地营养参考"))
        XCTAssertTrue(withNutritionContext.contains("dailyProteinGoalGrams"))
        XCTAssertFalse(withNutritionContext.contains("averageSleepMinutes"))
        XCTAssertFalse(withNutritionContext.contains("averageEnergyIntakeKcal"))
        XCTAssertFalse(withNutritionContext.contains("activityTrends"))
    }
}
