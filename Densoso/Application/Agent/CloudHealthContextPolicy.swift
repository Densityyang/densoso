import DensosoDomain
import Foundation

/// Provider-specific, opt-in permissions for historical health context.
/// Consent is stored in ProviderGovernanceRepository; a missing record is denied.
struct CloudHealthContextPolicy: Equatable, Sendable {
    static let dataClasses: [ProviderDataClass] = [
        .healthNutrition, .healthSleep, .healthActivity, .healthBody, .healthSubjective,
    ]

    let provider: ProviderID
    let allowedClasses: Set<ProviderDataClass>

    var revision: String {
        Self.dataClasses.map { allowedClasses.contains($0) ? "1" : "0" }.joined()
    }

    func allows(_ dataClass: ProviderDataClass) -> Bool {
        allowedClasses.contains(dataClass)
    }

    var allowsDerivedRecovery: Bool {
        allows(.healthSleep) && allows(.healthActivity) && allows(.healthBody)
    }

    static func load(from repository: any ProviderGovernanceRepository, provider: ProviderID) async throws -> Self {
        let firstSnapshot = try await consentSnapshot(from: repository, provider: provider, classes: dataClasses)
        let secondSnapshot = try await consentSnapshot(from: repository, provider: provider, classes: dataClasses)
        // If consent changes during the asynchronous reads, prefer the class that was denied in either pass.
        return Self(provider: provider, allowedClasses: firstSnapshot.intersection(secondSnapshot))
    }

    /// Starts the provider operation synchronously after the final conservative consent read.
    static func withCurrentSendConsent<Result: Sendable>(
        from repository: any ProviderGovernanceRepository,
        provider: ProviderID,
        expectedHealthPolicy: Self,
        includesImage: Bool,
        operation: @Sendable () throws -> Result
    ) async throws -> Result {
        let classes = dataClasses + [.healthText] + (includesImage ? [.mealImage] : [])
        let firstSnapshot = try await consentSnapshot(from: repository, provider: provider, classes: classes)
        let secondSnapshot = try await consentSnapshot(from: repository, provider: provider, classes: classes)
        let current = firstSnapshot.intersection(secondSnapshot)

        guard current.contains(.healthText) else {
            throw ProviderError.consentRequired(provider: provider, dataClass: .healthText)
        }
        if includesImage, !current.contains(.mealImage) {
            throw ProviderError.consentRequired(provider: provider, dataClass: .mealImage)
        }
        let currentHealthClasses = current.intersection(Set(dataClasses))
        guard currentHealthClasses.isSuperset(of: expectedHealthPolicy.allowedClasses) else {
            let revokedClass = expectedHealthPolicy.allowedClasses.subtracting(currentHealthClasses)
                .sorted { $0.rawValue < $1.rawValue }.first ?? .healthText
            throw ProviderError.consentRequired(provider: provider, dataClass: revokedClass)
        }
        return try operation()
    }

    private static func consentSnapshot(
        from repository: any ProviderGovernanceRepository,
        provider: ProviderID,
        classes: [ProviderDataClass]
    ) async throws -> Set<ProviderDataClass> {
        var allowed = Set<ProviderDataClass>()
        for dataClass in classes {
            if try await repository.isConsentGranted(provider: provider, dataClass: dataClass) {
                allowed.insert(dataClass)
            }
        }
        return allowed
    }
}

/// Applies health-context provenance rules before prompt construction and again
/// to provider-bound continuation messages. Derived recovery is withheld unless
/// all of its source classes are permitted.
enum CloudRequestPolicyGuard {
    static func filtered(_ context: HealthNarrativeContext?, by policy: CloudHealthContextPolicy) -> HealthNarrativeContext? {
        guard let context else { return nil }
        guard !policy.allowedClasses.isEmpty else { return nil }

        let filteredState: HealthStateV2?
        if policy.allows(.healthActivity), let state = context.healthState {
            let domains = state.domains.filter { policy.allows($0.domain) }
            let recovery = policy.allowsDerivedRecovery
                ? state.recovery
                : RecoveryAssessment(
                    status: .insufficientEvidence,
                    confidence: .low,
                    evidence: [],
                    recommendedAction: .collectData
                )
            filteredState = HealthStateV2(
                domains: domains,
                recovery: recovery,
                trainingLoad: state.trainingLoad,
                tomorrowGuidance: policy.allowsDerivedRecovery ? state.tomorrowGuidance : nil
            )
        } else {
            // HealthStateV2 requires a numeric TrainingLoadSummary. Do not serialize
            // placeholder zeros when activity is not authorized; summary fields
            // and individually sourced evidence below still carry allowed classes.
            filteredState = nil
        }

        let evidence = context.evidence.filter { policy.allows(source: $0.source) }
        let recommendations = context.recommendationCandidates.filter { recommendation in
            guard policy.allows(recommendation.domain),
                  policy.allows(evidenceKey: recommendation.evidenceKey) else { return false }
            if recommendation.id.hasPrefix("recovery.") { return policy.allowsDerivedRecovery }
            if recommendation.domain == .nutrition { return policy.allows(.healthActivity) }
            return true
        }
        let subjective = policy.allows(.healthSubjective) ? context.subjectiveContext : nil
        let summary = context.aggregateSummary.map { filtered($0, by: policy) }
        guard filteredState != nil || summary != nil || subjective != nil || !recommendations.isEmpty else {
            return nil
        }
        return HealthNarrativeContext(
            healthState: filteredState,
            evidence: evidence,
            recommendationCandidates: recommendations,
            aggregateSummary: summary,
            subjectiveContext: subjective
        )
    }

    static func filtered(_ summary: HealthContextSummary, by policy: CloudHealthContextPolicy) -> HealthContextSummary {
        func window(_ value: HealthContextWindowSummary) -> HealthContextWindowSummary {
            let coverage = value.coverageDays.filter { key, _ in
                policy.allows(coverageKey: key)
            }
            let dataCoverage = value.dataCoverage.filter { key, _ in
                policy.allows(coverageKey: key)
            }
            return HealthContextWindowSummary(
                windowDays: value.windowDays,
                coverageDays: coverage,
                averageSleepMinutes: policy.allows(.healthSleep) ? value.averageSleepMinutes : nil,
                averageStepCount: policy.allows(.healthActivity) ? value.averageStepCount : nil,
                averageActiveEnergyKcal: policy.allows(.healthActivity) ? value.averageActiveEnergyKcal : nil,
                averageEnergyIntakeKcal: policy.allows(.healthNutrition) ? value.averageEnergyIntakeKcal : nil,
                averageDailyDeficitKcal: policy.allows(.healthNutrition) && policy.allows(.healthActivity)
                    ? value.averageDailyDeficitKcal : nil,
                averageProteinGrams: policy.allows(.healthNutrition) ? value.averageProteinGrams : nil,
                medianWeightKilograms: policy.allows(.healthBody) ? value.medianWeightKilograms : nil,
                dataCoverage: dataCoverage
            )
        }
        let allowedReferencePrefixes = Set([
            policy.allows(.healthNutrition) ? "nutrition" : nil,
            policy.allows(.healthSleep) ? "sleep" : nil,
            policy.allows(.healthActivity) ? "activity" : nil,
            policy.allows(.healthBody) ? "body" : nil,
        ].compactMap { $0 })
        return HealthContextSummary(
            sevenDay: window(summary.sevenDay),
            twentyEightDay: window(summary.twentyEightDay),
            targetWeightKilograms: policy.allows(.healthBody) ? summary.targetWeightKilograms : nil,
            dailyDeficitGoalKcal: policy.allows(.healthNutrition) && policy.allows(.healthActivity)
                ? summary.dailyDeficitGoalKcal : nil,
            dailyProteinGoalGrams: policy.allows(.healthNutrition) ? summary.dailyProteinGoalGrams : nil,
            recommendationReferences: summary.recommendationReferences.filter { reference in
                allowedReferencePrefixes.contains(String(reference.split(separator: ".").first ?? ""))
            }
        )
    }

    static func filterConversationHistory(
        _ messages: [ModelMessage],
        currentTurnStartIndex: Int,
        by policy: CloudHealthContextPolicy
    ) -> [ModelMessage] {
        guard !allHealthClassesAllowed(policy), messages.indices.contains(currentTurnStartIndex) else {
            return messages
        }
        var output: [ModelMessage] = []
        var turn: [ModelMessage] = []
        var isCurrentTurn = false
        func flush() {
            guard !turn.isEmpty else { return }
            let userText = turn.first(where: { $0.role == .user }).flatMap { plainText(in: $0) } ?? ""
            let containsHealthTool = turn.contains { message in
                message.content.contains { content in
                    if case .toolCall(let call) = content { return healthToolNames.contains(call.name) }
                    return false
                }
            }
            if isCurrentTurn || (!HealthContextPromptBuilder.shouldIncludeSummary(for: userText) && !containsHealthTool) {
                output.append(contentsOf: turn)
            }
            turn.removeAll(keepingCapacity: true)
        }
        for (index, message) in messages.enumerated() {
            if message.role == .user && !turn.isEmpty { flush() }
            if index == currentTurnStartIndex { isCurrentTurn = true }
            turn.append(message)
        }
        flush()
        return output
    }

    static func filterToolResults(in messages: [ModelMessage], by policy: CloudHealthContextPolicy) -> [ModelMessage] {
        var namesByCallID: [String: String] = [:]
        for message in messages {
            for item in message.content {
                if case .toolCall(let call) = item { namesByCallID[call.id] = call.name }
            }
        }
        return messages.map { message in
            let content = message.content.map { item -> ModelContent in
                guard case .toolResult(let callID, let result) = item,
                      let name = namesByCallID[callID],
                      let filtered = filterToolResult(name: name, result: result, by: policy) else { return item }
                return .toolResult(toolCallID: callID, content: filtered)
            }
            return ModelMessage(role: message.role, content: content, inputEnvelope: message.inputEnvelope)
        }
    }

    private static func filterToolResult(name: String, result: String, by policy: CloudHealthContextPolicy) -> String? {
        switch name {
        case "get_today_health_state":
            return filterTodayHealthState(result, by: policy)
        case "get_health_history":
            return filterHealthHistory(result, by: policy)
        case "get_recent_meals":
            return policy.allows(.healthNutrition) ? nil : restrictedResult
        case "get_metrics", "get_weekly_deficit":
            return policy.allows(.healthNutrition) && policy.allows(.healthActivity) ? nil : restrictedResult
        case "get_recent_workouts", "get_schedule", "get_today_plan":
            return policy.allows(.healthActivity) ? nil : restrictedResult
        case "get_goal":
            return filterGoalResult(result, by: policy)
        default:
            return nil
        }
    }

    private static let restrictedResult = #"{"status":"not_authorized","message":"这些健康数据类别尚未获准用于云端上下文。"}"#
    private static let healthToolNames: Set<String> = [
        "get_today_health_state", "get_health_history", "get_recent_meals", "get_metrics",
        "get_weekly_deficit", "get_recent_workouts", "get_schedule", "get_today_plan", "get_goal",
    ]

    private static func filterTodayHealthState(_ text: String, by policy: CloudHealthContextPolicy) -> String {
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              var root = decoded.objectValue else {
            return restrictedResult
        }
        var safeRoot: [String: JSONValue] = [:]
        safeRoot["asOf"] = root["asOf"]
        if var state = root["healthState"]?.objectValue {
            if case .array(let domains)? = state["domains"] {
                safeRoot["healthState"] = .object([
                    "domains": .array(domains.filter { item in
                    guard let domain = item.objectValue?["domain"]?.stringValue,
                          let dataClass = classForDomain(domain) else { return false }
                    return policy.allows(dataClass)
                    }),
                ])
            } else {
                safeRoot["healthState"] = .object(["domains": .array([])])
            }
            var safeState = safeRoot["healthState"]?.objectValue ?? [:]
            if policy.allowsDerivedRecovery, let recovery = state["recovery"] {
                safeState["recovery"] = recovery
            } else {
                safeState["recovery"] = .object([
                    "status": .string("insufficientEvidence"),
                    "confidence": .string("low"),
                    "evidence": .array([]),
                    "recommendedAction": .string("collectData"),
                ])
            }
            if policy.allows(.healthActivity), let trainingLoad = state["trainingLoad"] {
                safeState["trainingLoad"] = trainingLoad
            }
            safeState["tomorrowGuidance"] = policy.allowsDerivedRecovery
                ? state["tomorrowGuidance"] ?? .null
                : .null
            safeRoot["healthState"] = .object(safeState)
        } else {
            safeRoot["healthState"] = .null
        }
        var safeReferences: [JSONValue] = []
        if case .array(let references)? = root["evidenceReferences"] {
            safeReferences = references.filter { item in
                guard let source = item.objectValue?["source"]?.stringValue else { return false }
                return policy.allows(source: source)
            }
        }
        safeRoot["evidenceReferences"] = .array(safeReferences)
        safeRoot["status"] = .string("policyFiltered")
        safeRoot["message"] = .string(policy.allowedClasses.isEmpty
            ? "没有获准用于云端的健康数据类别。"
            : "只包含已授权的健康数据类别；未展示类别不代表没有记录。")
        return encode(.object(safeRoot)) ?? restrictedResult
    }

    private static func filterGoalResult(_ text: String, by policy: CloudHealthContextPolicy) -> String {
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              let root = decoded.objectValue else {
            return restrictedResult
        }
        let canReadNutritionGoals = policy.allows(.healthNutrition)
        let canReadBodyGoals = policy.allows(.healthBody)
        guard canReadNutritionGoals || canReadBodyGoals else { return restrictedResult }

        let sourceGoal = root["goal"]?.objectValue ?? [:]
        var safeGoal: [String: JSONValue] = [:]
        if canReadBodyGoals, let value = sourceGoal["targetWeightKilograms"], value != .null {
            safeGoal["targetWeightKilograms"] = value
        }
        if canReadNutritionGoals, let value = sourceGoal["dailyProteinGrams"], value != .null {
            safeGoal["dailyProteinGrams"] = value
        }
        if canReadNutritionGoals, policy.allows(.healthActivity),
           let value = sourceGoal["dailyDeficitKcal"], value != .null {
            safeGoal["dailyDeficitKcal"] = value
        }
        if !safeGoal.isEmpty, let effectiveFrom = sourceGoal["effectiveFrom"], effectiveFrom != .null {
            safeGoal["effectiveFrom"] = effectiveFrom
        }

        let hasVisibleGoal = !safeGoal.isEmpty
        var safeRoot: [String: JSONValue] = [:]
        safeRoot["asOf"] = root["asOf"]
        safeRoot["goal"] = hasVisibleGoal ? .object(safeGoal) : .null
        safeRoot["status"] = .string(hasVisibleGoal ? "available" : "unavailable")
        safeRoot["message"] = .string(hasVisibleGoal
            ? "仅包含已授权类别的健康目标。"
            : "获准类别没有可显示的健康目标；未显示类别不代表没有目标。")
        return encode(.object(safeRoot)) ?? restrictedResult
    }

    private static func filterHealthHistory(_ text: String, by policy: CloudHealthContextPolicy) -> String {
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              var root = decoded.objectValue else {
            return restrictedResult
        }
        var filteredDays: [[String: JSONValue]] = []
        if case .array(let days)? = root["days"] {
            for value in days {
                guard case .object(let day) = value else { continue }
                let statuses: [String: JSONValue]
                if case .object(let source)? = day["domainStatuses"] {
                    statuses = source.filter { key, _ in
                        classForDomain(key).map(policy.allows) == true
                    }
                } else {
                    statuses = [:]
                }
                let observations: [String: JSONValue]
                if case .object(let source)? = day["observations"] {
                    observations = source.filter { key, _ in policy.allows(evidenceKey: key) }
                } else {
                    observations = [:]
                }
                var safeDay: [String: JSONValue] = [:]
                safeDay["date"] = day["date"]
                safeDay["domainStatuses"] = .object(statuses)
                safeDay["observations"] = .object(observations)
                if policy.allowsDerivedRecovery, let recovery = day["recoveryStatus"] {
                    safeDay["recoveryStatus"] = recovery
                }
                if policy.allows(.healthActivity), let trainingLoad = day["trainingLoadBand"] {
                    safeDay["trainingLoadBand"] = trainingLoad
                }

                // A date with only forbidden-class fields is itself a side channel.
                // Keep a day only when at least one authorized class contributed a field.
                guard !statuses.isEmpty || !observations.isEmpty
                    || safeDay["recoveryStatus"] != nil || safeDay["trainingLoadBand"] != nil else { continue }
                filteredDays.append(safeDay)
            }
        }
        var safeRoot: [String: JSONValue] = [:]
        safeRoot["startDate"] = root["startDate"]
        safeRoot["endDate"] = root["endDate"]
        safeRoot["days"] = .array(filteredDays.map { .object($0) })

        let hasObservations = filteredDays.contains { day in
            day["observations"]?.objectValue.map { !$0.isEmpty } == true
        }
        let hasUnknownOrPartialCoverage = filteredDays.contains { day in
            day["domainStatuses"]?.objectValue?.values.contains { value in
                value.stringValue == "unknown" || value.stringValue == "partial"
            } == true
        }
        let hasGaps = filteredDays.contains { day in
            let hasDomainGap = day["domainStatuses"]?.objectValue?.values.contains { value in
                value.stringValue == "noData"
                    || value.stringValue == "learning"
                    || value.stringValue == "unknown"
                    || value.stringValue == "partial"
            } == true
            let hasRecoveryGap = day["recoveryStatus"]?.stringValue == "insufficientEvidence"
            return hasDomainGap || hasRecoveryGap
        }
        let status: String
        let message: String
        if policy.allowedClasses.isEmpty {
            status = "notAuthorized"
            message = "没有获准用于云端的健康数据类别。"
        } else if hasUnknownOrPartialCoverage {
            status = "partial"
            message = "已授权类别的覆盖状态未知或不完整；不能据此断言没有记录。"
        } else if !hasObservations {
            status = "noData"
            message = "已授权类别没有可用观测；未授权或未显示类别不代表没有记录。"
        } else if hasGaps {
            status = "partial"
            message = "已授权类别的部分日期或领域证据不足；未授权类别不代表没有记录。"
        } else {
            status = "available"
            message = "仅依据已授权类别的观测汇总。"
        }
        safeRoot["status"] = .string(status)
        safeRoot["message"] = .string(message)
        return encode(.object(safeRoot)) ?? restrictedResult
    }

    private static func encode(_ value: JSONValue) -> String? {
        guard let data = try? value.encodedData() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func plainText(in message: ModelMessage) -> String? {
        message.content.compactMap { item in
            if case .text(let text) = item { return text }
            return nil
        }.joined(separator: "\n")
    }

    private static func allHealthClassesAllowed(_ policy: CloudHealthContextPolicy) -> Bool {
        CloudHealthContextPolicy.dataClasses.allSatisfy { policy.allows($0) }
    }

    private static func classForDomain(_ rawValue: String) -> ProviderDataClass? {
        switch rawValue {
        case "nutrition": .healthNutrition
        case "sleep": .healthSleep
        case "activity": .healthActivity
        case "body": .healthBody
        default: nil
        }
    }

}

private extension CloudHealthContextPolicy {
    func allows(_ domain: HealthDomain) -> Bool {
        switch domain {
        case .nutrition: allows(.healthNutrition)
        case .sleep: allows(.healthSleep)
        case .activity: allows(.healthActivity)
        case .body: allows(.healthBody)
        }
    }

    func allows(source: String) -> Bool {
        let normalized = source.lowercased()
        switch normalized {
        case "subjective", "subjectivehealth", "userreported", "userreporteddailycheckin":
            return allows(.healthSubjective)
        case "sleep", "sleepanalysis":
            return allows(.healthSleep)
        case "activity", "trainingload", "workouts", "steps", "activeenergy", "exercise":
            return allows(.healthActivity)
        case "nutrition", "energyintake", "protein":
            return allows(.healthNutrition)
        case "body", "vitals", "bodyweight", "restingheartrate", "heartratevariability",
             "respiratoryrate", "wristtemperature", "bodymass", "weight":
            return allows(.healthBody)
        default:
            break
        }
        if normalized.hasPrefix("sleep.") { return allows(.healthSleep) }
        if normalized.hasPrefix("activity.") || normalized.hasPrefix("trainingload.") {
            return allows(.healthActivity)
        }
        if normalized.hasPrefix("nutrition.") { return allows(.healthNutrition) }
        if normalized.hasPrefix("body.") || normalized.hasPrefix("vitals.") { return allows(.healthBody) }
        if normalized.hasPrefix("subjective.") || normalized.hasPrefix("userreported.") {
            return allows(.healthSubjective)
        }
        return false
    }

    func allows(evidenceKey: String) -> Bool {
        let normalized = evidenceKey.lowercased()
        if normalized == "trainingload.ratio" { return allows(.healthActivity) }
        return allows(source: normalized)
    }

    func allows(coverageKey: String) -> Bool {
        let normalized = coverageKey.lowercased()
        if normalized.contains("deficit") {
            return allows(.healthNutrition) && allows(.healthActivity)
        }
        return allows(source: normalized)
    }
}
