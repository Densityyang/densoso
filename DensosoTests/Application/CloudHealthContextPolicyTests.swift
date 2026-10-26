import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class CloudHealthContextPolicyTests: XCTestCase {
    func testGranularConsentPersistsPerProviderAndDefaultsToDenied() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataProviderGovernanceRepository(modelContainer: container)

        let initial = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)
        XCTAssertTrue(initial.allowedClasses.isEmpty)

        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .healthActivity,
            granted: true,
            policyVersion: "cloud-health-context-v1"
        )
        let updated = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)
        XCTAssertEqual(updated.allowedClasses, [.healthActivity])
        XCTAssertNotEqual(updated.revision, initial.revision)

        let otherProvider = try await CloudHealthContextPolicy.load(from: repository, provider: .qwen)
        XCTAssertTrue(otherProvider.allowedClasses.isEmpty)

        try await repository.setConsent(
            provider: .deepSeek,
            dataClass: .healthActivity,
            granted: false,
            policyVersion: "cloud-health-context-v1"
        )
        let revoked = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)
        XCTAssertFalse(revoked.allows(.healthActivity))
        XCTAssertEqual(revoked.allowedClasses, [])
        XCTAssertNotEqual(revoked.revision, updated.revision)
    }

    func testPolicySnapshotIntersectsReadsWhenConsentIsRevokedMidLoad() async throws {
        let repository = RevokesSleepConsentDuringSnapshotRepository()

        let policy = try await CloudHealthContextPolicy.load(from: repository, provider: .deepSeek)

        XCTAssertFalse(policy.allows(.healthSleep))
        XCTAssertTrue(policy.allows(.healthActivity))
    }

    func testUnconfiguredPolicyOmitsAutomaticHistoricalContext() {
        let policy = CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [])
        let context = makeContext()

        XCTAssertNil(CloudRequestPolicyGuard.filtered(context, by: policy))
        XCTAssertFalse(policy.allows(.healthSleep))
        XCTAssertFalse(policy.allows(.healthActivity))
    }

    func testSummaryKeepsOnlyAuthorizedCategoriesAndDropsCrossDomainDerivations() {
        let policy = CloudHealthContextPolicy(
            provider: .deepSeek,
            allowedClasses: [.healthSleep, .healthActivity]
        )
        let filtered = CloudRequestPolicyGuard.filtered(makeContext(), by: policy)

        XCTAssertEqual(filtered?.aggregateSummary?.sevenDay.averageSleepMinutes, 420)
        XCTAssertEqual(filtered?.aggregateSummary?.sevenDay.averageStepCount, 8_000)
        XCTAssertNil(filtered?.aggregateSummary?.sevenDay.averageEnergyIntakeKcal)
        XCTAssertNil(filtered?.aggregateSummary?.sevenDay.medianWeightKilograms)
        XCTAssertNil(filtered?.aggregateSummary?.sevenDay.averageDailyDeficitKcal)
        XCTAssertEqual(
            Set(filtered?.aggregateSummary?.sevenDay.coverageDays.keys.map { $0 } ?? []),
            Set(["sleep", "steps"])
        )
        XCTAssertEqual(filtered?.healthState?.recovery.status, .insufficientEvidence)
        XCTAssertNil(filtered?.healthState?.tomorrowGuidance)
        XCTAssertEqual(filtered?.healthState?.trainingLoad.band, .nearTypical)

        let sleepOnlyPolicy = CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [.healthSleep])
        let sleepOnly = CloudRequestPolicyGuard.filtered(makeContext(), by: sleepOnlyPolicy)
        XCTAssertNil(sleepOnly?.healthState)
        XCTAssertNil(sleepOnly?.aggregateSummary?.sevenDay.averageStepCount)
        XCTAssertNil(sleepOnly?.aggregateSummary?.sevenDay.averageActiveEnergyKcal)
        XCTAssertNil(sleepOnly?.aggregateSummary?.sevenDay.averageEnergyIntakeKcal)
        XCTAssertEqual(
            Set(sleepOnly?.aggregateSummary?.sevenDay.coverageDays.keys.map { $0 } ?? []),
            Set(["sleep"])
        )
    }

    func testProviderContinuationRemovesForbiddenSleepAndSleepDerivedRecovery() throws {
        let policy = CloudHealthContextPolicy(
            provider: .qwen,
            allowedClasses: [.healthActivity]
        )
        let payload = #"{"status":"available","healthState":{"domains":[{"domain":"sleep","currentValue":999,"evidenceKeys":["sleep-secret"]},{"domain":"activity","currentValue":123,"evidenceKeys":["activity-visible"]}],"recovery":{"status":"attention","evidence":[{"key":"sleep-secret","source":"sleep"}]},"trainingLoad":{"recentSevenDayLoad":123,"band":"increased"},"tomorrowGuidance":{"conditionalNote":"sleep-secret"}},"evidenceReferences":[{"key":"sleep-secret","source":"sleep"},{"key":"activity-visible","source":"activity"}]}"#
        let messages = [
            ModelMessage(role: .assistant, content: [
                .toolCall(ToolCall(id: "health-state", name: "get_today_health_state", arguments: .object([:])))
            ]),
            ModelMessage(role: .tool, content: [
                .toolResult(toolCallID: "health-state", content: payload)
            ]),
        ]

        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        let sentContent = filtered.flatMap(\.content).compactMap { content -> String? in
            if case .toolResult(_, let value) = content { return value }
            return nil
        }.joined()

        XCTAssertTrue(sentContent.contains("activity-visible"))
        XCTAssertTrue(sentContent.contains("123"))
        XCTAssertFalse(sentContent.contains("sleep-secret"))
        XCTAssertFalse(sentContent.contains("999"))
        XCTAssertFalse(sentContent.contains("\"status\":\"attention\""))
    }

    func testGoalContinuationOmitsDailyDeficitWhenActivityIsNotAuthorized() throws {
        let policy = CloudHealthContextPolicy(
            provider: .qwen,
            allowedClasses: [.healthNutrition, .healthBody]
        )
        let payload = #"{"status":"available","asOf":"2026-10-01","goal":{"effectiveFrom":"2026-09-01","targetWeightKilograms":58,"dailyDeficitKcal":300,"dailyProteinGrams":100},"message":"local goal profile"}"#
        let messages = [
            ModelMessage(role: .assistant, content: [
                .toolCall(ToolCall(id: "goal", name: "get_goal", arguments: .object([:]))),
            ]),
            ModelMessage(role: .tool, content: [
                .toolResult(toolCallID: "goal", content: payload),
            ]),
        ]

        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        guard case .toolResult(_, let result)? = filtered.last?.content.first,
              let data = result.data(using: .utf8),
              let json = try JSONDecoder().decode(JSONValue.self, from: data).objectValue,
              let goal = json["goal"]?.objectValue else {
            return XCTFail("Expected a category-filtered goal result")
        }

        XCTAssertEqual(json["status"]?.stringValue, "available")
        XCTAssertEqual(goal["targetWeightKilograms"]?.doubleValue, 58)
        XCTAssertEqual(goal["dailyProteinGrams"]?.doubleValue, 100)
        XCTAssertNil(goal["dailyDeficitKcal"])
        XCTAssertFalse(result.contains("dailyDeficitKcal"))
        XCTAssertFalse(result.contains("300"))
    }

    func testFinalHealthHistoryContinuationFailsClosedForEveryDeniedClassSentinel() throws {
        let scenarios: [(
            denied: ProviderDataClass,
            sentinels: [String],
            allowedSentinel: String,
            removesDerivedRecovery: Bool,
            removesTrainingLoad: Bool
        )] = [
            (
                .healthNutrition,
                [
                    "nutrition-status-sentinel",
                    "nutrition.value.SENTINEL",
                    "nutrition.derived.SENTINEL",
                    "10101",
                    "10102",
                ],
                "sleep.value.SENTINEL",
                false,
                false
            ),
            (
                .healthSleep,
                ["sleep-status-sentinel", "sleep.value.SENTINEL", "sleep.derived.SENTINEL", "20201", "20202"],
                "activity.value.SENTINEL",
                true,
                false
            ),
            (
                .healthActivity,
                [
                    "activity-status-sentinel",
                    "activity.value.SENTINEL",
                    "activity.derived.SENTINEL",
                    "trainingLoad.derived.SENTINEL",
                    "30301",
                    "30302",
                    "30303",
                ],
                "body.value.SENTINEL",
                true,
                true
            ),
            (
                .healthBody,
                ["body-status-sentinel", "body.value.SENTINEL", "body.derived.SENTINEL", "40401", "40402"],
                "nutrition.value.SENTINEL",
                true,
                false
            ),
            (
                .healthSubjective,
                ["subjective-status-sentinel", "subjective.value.SENTINEL", "subjective.derived.SENTINEL", "50501", "50502"],
                "activity.value.SENTINEL",
                false,
                false
            ),
        ]
        let payloadObject: [String: Any] = [
            "status": "available",
            "message": "unfiltered-root-message-sentinel",
            "startDate": "2026-10-01",
            "endDate": "2026-10-01",
            "days": [[
                "date": "2026-10-01",
                "domainStatuses": [
                    "nutrition": "nutrition-status-sentinel",
                    "sleep": "sleep-status-sentinel",
                    "activity": "activity-status-sentinel",
                    "body": "body-status-sentinel",
                    "subjective": "subjective-status-sentinel",
                ],
                "observations": [
                    "nutrition.value.SENTINEL": 10101,
                    "nutrition.derived.SENTINEL": 10102,
                    "sleep.value.SENTINEL": 20201,
                    "sleep.derived.SENTINEL": 20202,
                    "activity.value.SENTINEL": 30301,
                    "activity.derived.SENTINEL": 30302,
                    "trainingLoad.derived.SENTINEL": 30303,
                    "body.value.SENTINEL": 40401,
                    "body.derived.SENTINEL": 40402,
                    "subjective.value.SENTINEL": 50501,
                    "subjective.derived.SENTINEL": 50502,
                ],
                "recoveryStatus": "recovery.derived.SENTINEL",
                "trainingLoadBand": "trainingLoad.derived.SENTINEL",
            ]],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
        let payload = String(decoding: payloadData, as: UTF8.self)

        for provider in [ProviderID.deepSeek, .qwen] {
            for scenario in scenarios {
                let allowed = Set(CloudHealthContextPolicy.dataClasses).subtracting([scenario.denied])
                let policy = CloudHealthContextPolicy(provider: provider, allowedClasses: allowed)
                let callID = "history-\(provider.rawValue)-\(scenario.denied.rawValue)"
                let messages = [
                    ModelMessage(role: .assistant, content: [
                        .toolCall(ToolCall(id: callID, name: "get_health_history", arguments: .object([:])))
                    ]),
                    ModelMessage(role: .tool, content: [
                        .toolResult(toolCallID: callID, content: payload)
                    ]),
                ]

                let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
                guard case .toolResult(_, let result)? = filtered.last?.content.first else {
                    return XCTFail("Expected final filtered tool result for \(provider.rawValue), denied \(scenario.denied.rawValue)")
                }

                for sentinel in scenario.sentinels {
                    XCTAssertFalse(
                        result.localizedCaseInsensitiveContains(sentinel),
                        "Denied \(scenario.denied.rawValue) sentinel leaked for \(provider.rawValue): \(sentinel)"
                    )
                }
                XCTAssertTrue(
                    result.localizedCaseInsensitiveContains(scenario.allowedSentinel),
                    "An allowed category should remain for \(provider.rawValue) when denying \(scenario.denied.rawValue)"
                )
                if scenario.removesDerivedRecovery {
                    XCTAssertFalse(result.contains("recovery.derived.SENTINEL"))
                }
                if scenario.removesTrainingLoad {
                    XCTAssertFalse(result.contains("trainingLoad.derived.SENTINEL"))
                }
                XCTAssertFalse(result.contains("unfiltered-root-message-sentinel"))
            }
        }
    }

    func testProviderContinuationOmitsTrainingLoadWhenActivityIsNotAuthorized() throws {
        let policy = CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [.healthSleep])
        let payload = #"{"status":"available","healthState":{"domains":[{"domain":"sleep","currentValue":420,"evidenceKeys":["sleep-visible"]},{"domain":"activity","currentValue":9876,"evidenceKeys":["activity-secret"]}],"recovery":{"status":"attention","evidence":[{"key":"sleep-visible","source":"sleep"}]},"trainingLoad":{"recentSevenDayLoad":555,"estimatedWorkoutCount":12,"band":"increased"}}}"#
        let messages = [
            ModelMessage(role: .assistant, content: [
                .toolCall(ToolCall(id: "health-state", name: "get_today_health_state", arguments: .object([:])))
            ]),
            ModelMessage(role: .tool, content: [
                .toolResult(toolCallID: "health-state", content: payload)
            ]),
        ]

        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        let sentContent = filtered.flatMap(\.content).compactMap { content -> String? in
            if case .toolResult(_, let value) = content { return value }
            return nil
        }.joined()

        XCTAssertTrue(sentContent.contains("sleep-visible"))
        XCTAssertFalse(sentContent.contains("activity-secret"))
        XCTAssertFalse(sentContent.contains("9876"))
        XCTAssertFalse(sentContent.contains("555"))
        XCTAssertFalse(sentContent.contains("estimatedWorkoutCount"))
        XCTAssertFalse(sentContent.contains("trainingLoad"))
    }

    func testHealthHistoryRecomputesStatusFromAuthorizedFieldsAndDropsForbiddenOnlyDates() throws {
        let policy = CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [.healthActivity])
        let payload = #"{"status":"available","message":"sleep data was available","startDate":"2026-10-01","endDate":"2026-10-02","days":[{"date":"2026-10-01","domainStatuses":{"sleep":"attention"},"observations":{"sleep.mainSleep.minutes":999},"recoveryStatus":"attention"},{"date":"2026-10-02","domainStatuses":{"activity":"noData"},"observations":{},"recoveryStatus":"attention","trainingLoadBand":"unavailable"}]}"#
        let messages = [
            ModelMessage(role: .assistant, content: [
                .toolCall(ToolCall(id: "history", name: "get_health_history", arguments: .object([:])))
            ]),
            ModelMessage(role: .tool, content: [
                .toolResult(toolCallID: "history", content: payload)
            ]),
        ]

        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        guard case .toolResult(_, let result)? = filtered.last?.content.first,
              let data = result.data(using: .utf8),
              let json = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            return XCTFail("Expected filtered history JSON")
        }
        let days = json["days"]?.arrayValue ?? []

        XCTAssertEqual(json["status"]?.stringValue, "noData")
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.objectValue?["date"]?.stringValue, "2026-10-02")
        XCTAssertFalse(result.contains("sleep"))
        XCTAssertFalse(result.contains("999"))
        XCTAssertTrue(result.contains("已授权类别没有可用观测"))
    }

    func testAuthorizedUnknownHealthHistoryCoverageDoesNotBecomeNoDataOrZero() throws {
        let policy = CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [.healthActivity])
        let payload = #"{"status":"noData","message":"no observations","startDate":"2026-10-01","endDate":"2026-10-02","days":[{"date":"2026-10-01","domainStatuses":{"activity":"unknown","sleep":"attention"},"observations":{"sleep.mainSleep.minutes":9876543}},{"date":"2026-10-02","domainStatuses":{"activity":"partial","sleep":"attention"},"observations":{"sleep.mainSleep.minutes":9876543}}]}"#
        let messages = [
            ModelMessage(role: .assistant, content: [
                .toolCall(ToolCall(id: "history", name: "get_health_history", arguments: .object([:])))
            ]),
            ModelMessage(role: .tool, content: [
                .toolResult(toolCallID: "history", content: payload)
            ]),
        ]

        let filtered = CloudRequestPolicyGuard.filterToolResults(in: messages, by: policy)
        guard case .toolResult(_, let result)? = filtered.last?.content.first,
              let data = result.data(using: .utf8),
              let json = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            return XCTFail("Expected filtered history JSON")
        }
        let days = json["days"]?.arrayValue ?? []

        XCTAssertEqual(json["status"]?.stringValue, "partial")
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].objectValue?["domainStatuses"]?.objectValue?["activity"]?.stringValue, "unknown")
        XCTAssertEqual(days[1].objectValue?["domainStatuses"]?.objectValue?["activity"]?.stringValue, "partial")
        XCTAssertTrue(days.allSatisfy { $0.objectValue?["observations"]?.objectValue?.isEmpty == true })
        XCTAssertFalse(result.contains("noData"))
        XCTAssertFalse(result.contains("9876543"))
        XCTAssertFalse(result.contains("sleep"))
        XCTAssertTrue(result.contains("覆盖状态未知或不完整"))
    }

    func testRestrictedEarlierHealthTurnIsRemovedFromProviderHistory() {
        let policy = CloudHealthContextPolicy(provider: .deepSeek, allowedClasses: [.healthActivity])
        let messages = [
            ModelMessage(role: .user, text: "请分析我最近的睡眠和活动状态"),
            ModelMessage(role: .assistant, text: "睡眠时长为 999 分钟"),
            ModelMessage(role: .user, text: "下一件事"),
        ]

        let filtered = CloudRequestPolicyGuard.filterConversationHistory(
            messages,
            currentTurnStartIndex: 2,
            by: policy
        )
        let text = filtered.flatMap(\.content).compactMap { content -> String? in
            if case .text(let value) = content { return value }
            return nil
        }.joined()

        XCTAssertFalse(text.contains("999"))
        XCTAssertTrue(text.contains("下一件事"))
    }

    private func makeContext() -> HealthNarrativeContext {
        let window = HealthContextWindowSummary(
            windowDays: 7,
            coverageDays: [
                "sleep": 6,
                "steps": 7,
                "energyIntake": 5,
                "dailyDeficitKcal": 4,
                "bodyMass": 3,
                "sleepAndActivity": 2,
            ],
            averageSleepMinutes: 420,
            averageStepCount: 8_000,
            averageActiveEnergyKcal: 500,
            averageEnergyIntakeKcal: 1_900,
            averageDailyDeficitKcal: 250,
            averageProteinGrams: 90,
            medianWeightKilograms: 60
        )
        let summary = HealthContextSummary(
            sevenDay: window,
            twentyEightDay: window,
            targetWeightKilograms: 58,
            dailyDeficitGoalKcal: 300,
            dailyProteinGoalGrams: 100,
            recommendationReferences: ["sleep.consistency", "activity.gentle-adjustment", "nutrition.review-balance"]
        )
        let baseline = HealthBaseline(
            readiness: .mature,
            validDays: 28,
            median: 400,
            p10: 350,
            p90: 460,
            mad: 20
        )
        let state = HealthStateV2(
            domains: [
                HealthDomainResult(
                    domain: .sleep,
                    status: .attention,
                    currentValue: 420,
                    baseline: baseline,
                    evidenceKeys: ["sleep.latest"]
                ),
                HealthDomainResult(
                    domain: .activity,
                    status: .withinTypicalRange,
                    currentValue: 8_000,
                    baseline: baseline,
                    evidenceKeys: ["activity.steps"]
                ),
            ],
            recovery: RecoveryAssessment(
                status: .attention,
                confidence: .high,
                evidence: [EvidenceReference(key: "sleep.latest", source: "sleep")],
                recommendedAction: .reduceIntensity
            ),
            trainingLoad: TrainingLoadSummary(
                recentSevenDayLoad: 123,
                priorTwentyEightDayAverage: 100,
                ratio: 1.23,
                readiness: .mature,
                band: .nearTypical,
                estimatedWorkoutCount: 3,
                unavailableEffortCount: 0
            ),
            tomorrowGuidance: NextDayGuidance(
                expectedState: .caution,
                confidence: .high,
                reasons: [EvidenceReference(key: "sleep.latest", source: "sleep")],
                recommendedAction: .reduceIntensity,
                conditionalNote: "sleep derived recommendation"
            )
        )
        return HealthNarrativeContext(
            healthState: state,
            evidence: [
                EvidenceReference(key: "sleep.latest", source: "sleep"),
                EvidenceReference(key: "activity.steps", source: "activity"),
            ],
            recommendationCandidates: [],
            aggregateSummary: summary
        )
    }
}

private actor RevokesSleepConsentDuringSnapshotRepository: ProviderGovernanceRepository {
    private var granted = Set(CloudHealthContextPolicy.dataClasses)
    private var didRevokeSleep = false

    func isConsentGranted(provider: ProviderID, dataClass: ProviderDataClass) -> Bool {
        guard provider == .deepSeek else { return false }
        let wasGranted = granted.contains(dataClass)
        if dataClass == .healthSleep && !didRevokeSleep {
            didRevokeSleep = true
            granted.remove(.healthSleep)
        }
        return wasGranted
    }

    func setConsent(
        provider: ProviderID,
        dataClass: ProviderDataClass,
        granted: Bool,
        policyVersion: String
    ) {
        guard provider == .deepSeek else { return }
        if granted { self.granted.insert(dataClass) } else { self.granted.remove(dataClass) }
    }

    func recordUsage(
        usage: ProviderUsage,
        usageKey: String,
        requestID: UUID,
        estimatedCostMicros: Int64?,
        currency: String?,
        rateVersion: String
    ) -> Bool {
        false
    }

    func monthlyUsage(
        provider: ProviderID,
        monthStart: Date,
        monthEnd: Date
    ) -> ProviderUsageSummary {
        ProviderUsageSummary(
            provider: provider,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            imageCount: 0,
            audioSeconds: 0,
            averageLatencyMilliseconds: nil,
            estimatedCostMicros: nil,
            currency: nil
        )
    }
}
