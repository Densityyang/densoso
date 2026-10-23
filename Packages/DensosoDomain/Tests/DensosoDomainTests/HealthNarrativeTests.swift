import DensosoDomain
import XCTest

final class HealthNarrativeTests: XCTestCase {
    func testNarrativeCodableContainsOnlyNarrativeFieldsAndEvidenceKeys() throws {
        let narrative = HealthNarrative(
            headline: "今天可以按舒适节奏安排",
            summary: "目前可用证据没有显示明显偏离个人近期状态。",
            recommendations: ["继续留意睡眠后的感受。"],
            tomorrowGuidance: "根据今晚休息再安排明天运动。",
            evidenceKeys: ["sleep.consistency"]
        )

        let encoded = try JSONEncoder().encode(narrative)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["headline", "summary", "recommendations", "tomorrowGuidance", "evidenceKeys"])
        XCTAssertEqual(try JSONDecoder().decode(HealthNarrative.self, from: encoded), narrative)
    }

    func testAllowedEvidenceKeysExcludeRecommendationIDsAndUnknownReferences() throws {
        let context = HealthNarrativeContext(
            healthState: nil,
            evidence: [EvidenceReference(key: "body.weight.kg", source: "body")],
            recommendationCandidates: [
                HealthRecommendation(
                    id: "sleep.consistency",
                    domain: .sleep,
                    title: "维持作息",
                    detail: "保持规律作息。",
                    evidenceKey: "sleep.mainSleep.minutes",
                    conflictGroup: "sleep",
                    score: 0.8
                ),
            ],
            aggregateSummary: HealthContextSummary(
                sevenDay: .init(
                    windowDays: 7,
                    coverageDays: [:],
                    averageSleepMinutes: nil,
                    averageStepCount: nil,
                    averageActiveEnergyKcal: nil,
                    averageEnergyIntakeKcal: nil,
                    averageDailyDeficitKcal: nil,
                    averageProteinGrams: nil,
                    medianWeightKilograms: nil
                ),
                twentyEightDay: .init(
                    windowDays: 28,
                    coverageDays: [:],
                    averageSleepMinutes: nil,
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
                recommendationReferences: ["sleep.consistency", "sleep.mainSleep.minutes", "unrelated.key"]
            )
        )

        XCTAssertEqual(context.allowedEvidenceKeys, ["body.weight.kg", "sleep.mainSleep.minutes"])
        XCTAssertFalse(context.allowedEvidenceKeys.contains("sleep.consistency"))

        let encoded = try JSONEncoder().encode(context)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["allowedEvidenceKeys"] = ["forged.key"]
        let forged = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(HealthNarrativeContext.self, from: forged)
        XCTAssertEqual(decoded.allowedEvidenceKeys, ["body.weight.kg", "sleep.mainSleep.minutes"])
    }

    func testSubjectiveCheckInsRemainSeparateAndAddTheirOwnEvidenceKeys() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let older = SubjectiveHealthEntry(
            dayStart: day,
            occurredAt: day.addingTimeInterval(3_600),
            energy: .low,
            stress: .elevated,
            subjectiveSleep: .poor,
            evidenceKey: "userReportedCheckIn.older"
        )
        let latest = SubjectiveHealthEntry(
            dayStart: day,
            occurredAt: day.addingTimeInterval(7_200),
            energy: .typical,
            stress: .low,
            subjectiveSleep: .fair,
            evidenceKey: "userReportedCheckIn.latest"
        )
        let subjective = SubjectiveHealthContext(asOf: day.addingTimeInterval(8_000), entries: [older, latest])
        let context = HealthNarrativeContext(
            healthState: nil,
            evidence: [],
            recommendationCandidates: [],
            aggregateSummary: nil,
            subjectiveContext: subjective
        )

        XCTAssertEqual(context.subjectiveContext?.entries, [latest])
        XCTAssertNil(context.healthState)
        XCTAssertEqual(context.allowedEvidenceKeys, ["userReportedCheckIn.latest"])
        XCTAssertEqual(context.evidence.first?.source, "userReportedDailyCheckIn")

        let encoded = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(HealthNarrativeContext.self, from: encoded)
        XCTAssertEqual(decoded, context)

        let legacy = #"{"healthState":null,"evidence":[],"recommendationCandidates":[],"aggregateSummary":null}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(HealthNarrativeContext.self, from: legacy).subjectiveContext)
    }
}
