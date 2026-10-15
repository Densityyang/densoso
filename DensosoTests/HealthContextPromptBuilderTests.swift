import DensosoDomain
import XCTest
@testable import Densoso

final class HealthContextPromptBuilderTests: XCTestCase {
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
