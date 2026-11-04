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
    }

    func testBodyMetricInterpretationLoadsHealthContext() {
        XCTAssertTrue(HealthContextPromptBuilder.shouldIncludeSummary(for: "帮我解读一下体重和体脂变化"))
        XCTAssertTrue(HealthContextPromptBuilder.requiresNarrative(for: "帮我解读一下体重和体脂变化"))
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
}
