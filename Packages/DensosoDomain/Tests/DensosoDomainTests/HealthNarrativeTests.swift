import DensosoDomain
import XCTest

final class HealthNarrativeTests: XCTestCase {
    func testLegacyNutritionRecommendationInfersConservativeEvidenceDependencies() throws {
        func decode(_ id: String, detail: String) throws -> HealthRecommendation {
            let object: [String: Any] = [
                "id": id,
                "domain": HealthDomain.nutrition.rawValue,
                "title": "nutrition recommendation",
                "detail": detail,
                "evidenceKey": "nutrition.energyIntake.kcal",
                "conflictGroup": "nutrition",
                "score": 0.6,
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try JSONDecoder().decode(HealthRecommendation.self, from: data)
        }

        let pureNutrition = try decode(
            "nutrition.review-balance",
            detail: "可以回看餐食份量与记录完整度。"
        )
        XCTAssertEqual(pureNutrition.requiredDataDomains, [.nutrition])

        let goalAware = try decode(
            "nutrition.review-balance",
            detail: "可以结合自己的 400 kcal 日目标查看餐食份量。"
        )
        XCTAssertEqual(goalAware.requiredDataDomains, [.nutrition, .activity])

        let unknownLegacyRecommendation = try decode(
            "nutrition.legacy-unknown",
            detail: "旧版本营养建议。"
        )
        XCTAssertEqual(unknownLegacyRecommendation.requiredDataDomains, [.nutrition, .activity])
    }

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

    func testNarrativeContextOmitsUnknownTrainingLoadZeroPlaceholders() throws {
        let baseline = HealthBaseline(readiness: .noData, validDays: 0, median: nil, p10: nil, p90: nil, mad: nil)
        let state = HealthStateV2(
            domains: [HealthDomainResult(
                domain: .activity,
                status: .unknown,
                currentValue: nil,
                baseline: baseline,
                evidenceKeys: []
            )],
            recovery: RecoveryAssessment(
                status: .insufficientEvidence,
                confidence: .low,
                evidence: [],
                recommendedAction: .collectData
            ),
            trainingLoad: TrainingLoadSummary(
                recentSevenDayLoad: 0,
                priorTwentyEightDayAverage: 0,
                ratio: 0,
                readiness: .noData,
                band: .unavailable,
                estimatedWorkoutCount: 0,
                unavailableEffortCount: 0,
                dataCoverage: .unknown
            ),
            tomorrowGuidance: nil
        )
        let window = HealthContextWindowSummary(
            windowDays: 7,
            coverageDays: ["steps": 0, "energyIntake": 1],
            averageSleepMinutes: 0,
            averageStepCount: 0,
            averageActiveEnergyKcal: 0,
            averageEnergyIntakeKcal: 1_800,
            averageDailyDeficitKcal: 0,
            averageProteinGrams: 80,
            medianWeightKilograms: 0,
            dataCoverage: [
                "sleep": .unknown,
                "steps": .unknown,
                "activeEnergy": .unknown,
                "energyIntake": .complete,
                "dailyDeficitKcal": .unknown,
                "proteinGrams": .complete,
                "bodyMass": .unknown,
            ],
            metricWindowCoverage: [
                "energyIntake": HealthMetricWindowCoverage(
                    targetWindowStart: Date(timeIntervalSince1970: 1_800_000_000),
                    targetWindowEnd: Date(timeIntervalSince1970: 1_800_000_000 + 7 * 86_400),
                    expectedCalendarDays: 7,
                    actualEarliestDate: Date(timeIntervalSince1970: 1_800_000_000),
                    validCalendarDays: 1,
                    missingCalendarDays: 6,
                    completeRecordDays: 1,
                    completeValidDays: 1,
                    authorizationLimited: nil,
                    dataAvailabilityLimited: nil
                ),
            ]
        )
        let summary = HealthContextSummary(
            sevenDay: window,
            twentyEightDay: window,
            targetWeightKilograms: nil,
            dailyDeficitGoalKcal: nil,
            dailyProteinGoalGrams: nil,
            recommendationReferences: []
        )
        let context = HealthNarrativeContext(
            healthState: state,
            evidence: [],
            recommendationCandidates: [],
            aggregateSummary: summary
        )

        let encoded = try JSONEncoder().encode(context)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let healthState = try XCTUnwrap(object["healthState"] as? [String: Any])
        let domains = try XCTUnwrap(healthState["domains"] as? [[String: Any]])
        let trainingLoad = try XCTUnwrap(healthState["trainingLoad"] as? [String: Any])
        let aggregateSummary = try XCTUnwrap(object["aggregateSummary"] as? [String: Any])
        let sevenDay = try XCTUnwrap(aggregateSummary["sevenDay"] as? [String: Any])
        let coverage = try XCTUnwrap(sevenDay["dataCoverage"] as? [String: String])
        let coverageDays = try XCTUnwrap(sevenDay["coverageDays"] as? [String: Int])

        XCTAssertEqual(domains.first?["status"] as? String, HealthDomainStatus.unknown.rawValue)
        XCTAssertEqual(trainingLoad["dataCoverage"] as? String, HealthDataCoverage.unknown.rawValue)
        XCTAssertNil(trainingLoad["recentSevenDayLoad"])
        XCTAssertNil(trainingLoad["priorTwentyEightDayAverage"])
        XCTAssertNil(trainingLoad["ratio"])
        XCTAssertNil(trainingLoad["estimatedWorkoutCount"])
        XCTAssertNil(trainingLoad["unavailableEffortCount"])
        XCTAssertEqual(coverage["steps"], HealthDataCoverage.unknown.rawValue)
        XCTAssertNil(coverageDays["steps"])
        XCTAssertNil(sevenDay["averageStepCount"])
        XCTAssertEqual(sevenDay["averageEnergyIntakeKcal"] as? Double, 1_800)
    }

    func testNarrativeContextOmitsPartialEffortLoadValuesFromFinalJSON() throws {
        let baseline = HealthBaseline(readiness: .noData, validDays: 0, median: nil, p10: nil, p90: nil, mad: nil)
        let state = HealthStateV2(
            domains: [HealthDomainResult(
                domain: .activity,
                status: .unknown,
                currentValue: nil,
                baseline: baseline,
                evidenceKeys: [],
                dataCoverage: .unknown
            )],
            recovery: RecoveryAssessment(
                status: .insufficientEvidence,
                confidence: .low,
                evidence: [],
                recommendedAction: .collectData
            ),
            trainingLoad: TrainingLoadSummary(
                recentSevenDayLoad: 0,
                priorTwentyEightDayAverage: 525,
                ratio: nil,
                readiness: .mature,
                band: .unavailable,
                estimatedWorkoutCount: 7,
                unavailableEffortCount: 1,
                dataCoverage: .partial
            ),
            tomorrowGuidance: nil
        )
        let context = HealthNarrativeContext(
            healthState: state,
            evidence: [],
            recommendationCandidates: [],
            aggregateSummary: nil
        )

        let encoded = try JSONEncoder().encode(context)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let healthState = try XCTUnwrap(root["healthState"] as? [String: Any])
        let trainingLoad = try XCTUnwrap(healthState["trainingLoad"] as? [String: Any])

        XCTAssertEqual(trainingLoad["dataCoverage"] as? String, HealthDataCoverage.partial.rawValue)
        XCTAssertNil(trainingLoad["recentSevenDayLoad"])
        XCTAssertNil(trainingLoad["priorTwentyEightDayAverage"])
        XCTAssertNil(trainingLoad["ratio"])
        XCTAssertNil(trainingLoad["estimatedWorkoutCount"])
        XCTAssertNil(trainingLoad["unavailableEffortCount"])
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
        var forgedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var forgedTrends = try XCTUnwrap(forgedObject["activityTrends"] as? [[String: Any]])
        forgedTrends[0]["unit"] = "kcal"
        forgedObject["activityTrends"] = forgedTrends
        let mismatchedUnit = try JSONSerialization.data(withJSONObject: forgedObject)
        XCTAssertThrowsError(try JSONDecoder().decode(HealthNarrativeContext.self, from: mismatchedUnit))

        let legacy = #"{"healthState":null,"evidence":[],"recommendationCandidates":[],"aggregateSummary":null}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(HealthNarrativeContext.self, from: legacy).subjectiveContext)
    }

    func testActivityNarrativeContextKeepsOnlyCanonicalNumericEvidenceAndDecodesLegacyJSON() throws {
        let baseline = HealthBaseline(
            readiness: .mature,
            validDays: 14,
            median: 7_000,
            p10: 5_000,
            p90: 9_000,
            mad: 500
        )
        let context = HealthNarrativeContext(
            healthState: nil,
            evidence: [
                EvidenceReference(key: "activity.steps", source: HealthDomain.activity.rawValue),
                EvidenceReference(key: "activity.exerciseMinutes", source: HealthDomain.activity.rawValue),
                EvidenceReference(key: "activity.forged", source: HealthDomain.activity.rawValue),
            ],
            recommendationCandidates: [],
            aggregateSummary: nil,
            activityTrends: [
                ActivityMetricTrend(
                    metric: .steps,
                    currentValue: 8_100,
                    baselineWindowDays: 28,
                    baseline: baseline,
                    status: .withinTypicalRange,
                    dataCoverage: .complete
                ),
                ActivityMetricTrend(
                    metric: .exerciseMinutes,
                    currentValue: nil,
                    baselineWindowDays: 28,
                    baseline: baseline,
                    status: .unknown,
                    dataCoverage: .unknown
                ),
            ]
        )

        XCTAssertEqual(context.allowedEvidenceKeys, ["activity.steps"])
        XCTAssertEqual(context.evidence.map(\.source), [HealthDomain.activity.rawValue])
        XCTAssertNil(context.activityTrends[1].evidenceKey)

        let encoded = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(HealthNarrativeContext.self, from: encoded)
        XCTAssertEqual(decoded, context)

        let legacy = #"{"healthState":null,"evidence":[],"recommendationCandidates":[],"aggregateSummary":null}"#.data(using: .utf8)!
        XCTAssertTrue(try JSONDecoder().decode(HealthNarrativeContext.self, from: legacy).activityTrends.isEmpty)
    }
}
