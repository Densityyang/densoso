import DensosoDomain
import Foundation

struct MealEstimationNutritionContext: Codable, Equatable, Sendable {
    struct Today: Codable, Equatable, Sendable {
        let recordedEnergyIntakeKcal: EstimateRange?
        let recordedProteinGrams: Double?
        let intakeAvailability: MetricAvailability?
        let proteinAvailability: MetricAvailability?
        let intakeCoverage: MetricCoverage?
        let proteinCoverage: MetricCoverage?
        let nutritionRecordStatus: NutritionDayRecordStatus
        let allRecordedMealsHaveEvidence: Bool?
        let mealCount: Int
        let recordedThroughLocalTime: String?
        let mayCompareWithCompleteDayHistory: Bool
    }

    let today: Today?
    let sevenDay: HealthContextWindowSummary?
    let twentyEightDay: HealthContextWindowSummary?
    let analysisWindowCoverage: [String: HealthMetricWindowCoverage]
    let dailyProteinGoalGrams: Double?
    let evidenceKeys: [String]

    static func make(
        today metric: DailyMetricsReadResult?,
        summary: HealthContextSummary?
    ) -> MealEstimationNutritionContext? {
        let projectionRequiresRecompute = metric?.requiresRecompute ?? false
        let intake = usable(metric?.intake, projectionRequiresRecompute: projectionRequiresRecompute)
        let protein = usable(metric?.proteinG, projectionRequiresRecompute: projectionRequiresRecompute)
        let status = metric?.nutritionRecordStatus ?? .unknown
        let allAvailableTodayEstimatesAreComplete =
            (intake.value == nil || intake.availability == .estimated || intake.availability == .observed)
                && (protein.value == nil || protein.availability == .estimated || protein.availability == .observed)
        let mayCompareWithCompleteDayHistory = status == .complete
            && allAvailableTodayEstimatesAreComplete
            && (intake.value != nil || protein.value != nil)
        let today = metric != nil
            && (intake.value != nil || protein.value != nil || (metric?.mealCount ?? 0) > 0 || status == .complete)
            ? Today(
                recordedEnergyIntakeKcal: intake.value,
                recordedProteinGrams: protein.value,
                intakeAvailability: metric?.intake.availability,
                proteinAvailability: metric?.proteinG.availability,
                intakeCoverage: metric?.coverage.intake,
                proteinCoverage: metric?.coverage.proteinG,
                nutritionRecordStatus: status,
                allRecordedMealsHaveEvidence: metric?.allRecordedMealsHaveEvidence,
                mealCount: metric?.mealCount ?? 0,
                recordedThroughLocalTime: metric?.lastMealRecordedAt.map(localTimestamp),
                mayCompareWithCompleteDayHistory: mayCompareWithCompleteDayHistory
            )
            : nil
        let sevenDay = summary.map { nutritionOnly($0.sevenDay) }
        let twentyEightDay = summary.map { nutritionOnly($0.twentyEightDay) }
        let analysisCoverage = summary?.analysisWindowCoverage.filter { isNutritionKey($0.key) } ?? [:]
        let goal = summary?.dailyProteinGoalGrams
        guard today != nil || sevenDay != nil || twentyEightDay != nil || goal != nil else { return nil }
        var evidenceKeys: [String] = []
        if today?.recordedEnergyIntakeKcal != nil { evidenceKeys.append("nutrition.energyIntake.kcal") }
        if today?.recordedProteinGrams != nil { evidenceKeys.append("nutrition.protein.grams") }
        return MealEstimationNutritionContext(
            today: today,
            sevenDay: sevenDay,
            twentyEightDay: twentyEightDay,
            analysisWindowCoverage: analysisCoverage,
            dailyProteinGoalGrams: goal,
            evidenceKeys: evidenceKeys
        )
    }

    static func nutritionOnlySummary(from summary: HealthContextSummary?) -> HealthContextSummary? {
        guard let summary else { return nil }
        return HealthContextSummary(
            sevenDay: nutritionOnly(summary.sevenDay),
            twentyEightDay: nutritionOnly(summary.twentyEightDay),
            targetWeightKilograms: nil,
            dailyDeficitGoalKcal: nil,
            dailyProteinGoalGrams: summary.dailyProteinGoalGrams,
            recommendationReferences: [],
            analysisWindowCoverage: summary.analysisWindowCoverage.filter { isNutritionKey($0.key) }
        )
    }

    private static func nutritionOnly(_ window: HealthContextWindowSummary) -> HealthContextWindowSummary {
        let keys = Set(["energyIntake", "proteinGrams"])
        return HealthContextWindowSummary(
            windowDays: window.windowDays,
            coverageDays: window.coverageDays.filter { keys.contains($0.key) },
            averageSleepMinutes: nil,
            averageStepCount: nil,
            averageActiveEnergyKcal: nil,
            averageEnergyIntakeKcal: window.averageEnergyIntakeKcal,
            averageDailyDeficitKcal: nil,
            averageProteinGrams: window.averageProteinGrams,
            medianWeightKilograms: nil,
            dataCoverage: window.dataCoverage.filter { keys.contains($0.key) },
            metricWindowCoverage: window.metricWindowCoverage.filter { keys.contains($0.key) }
        )
    }

    private static func usable<Value: Codable & Equatable & Sendable>(
        _ value: MetricValue<Value>?,
        projectionRequiresRecompute: Bool
    ) -> (value: Value?, availability: MetricAvailability?) {
        guard !projectionRequiresRecompute else { return (nil, .pendingRecompute) }
        guard let value,
              value.availability == .observed
                || value.availability == .estimated
                || value.availability == .partial else {
            return (nil, value?.availability)
        }
        return (value.value, value.availability)
    }

    private static func isNutritionKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized == "energyintake" || normalized == "proteingrams"
    }

    private static func localTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter.string(from: date)
    }
}

enum HealthContextPromptBuilder {
    static let promptVersion = NarrativePromptVersion.current

    private static let healthEntityTerms = [
        "睡眠", "睡得", "睡觉", "睡不着", "睡不好", "没睡好", "睡了", "入睡", "夜醒", "老醒", "失眠",
        "sleep", "slept", "sleeping", "insomnia",
        "饮食", "吃了", "吃什么", "进食", "早餐", "午餐", "晚餐", "食材", "营养", "蛋白质", "碳水",
        "热量", "卡路里", "摄入", "meal", "food", "nutrition", "protein", "carbohydrate", "calorie", "intake",
        "体重", "静息心率", "心率变异", "呼吸频率", "腕温", "手腕温度",
        "weight", "body mass", "resting heart rate", "heart rate variability", "hrv",
        "respiratory rate", "wrist temperature",
        "运动", "训练", "锻炼", "跑步", "步数", "活动量", "运动负荷", "恢复", "疲劳", "酸痛",
        "workout", "exercise", "training", "running", "steps", "activity", "recovery", "fatigue", "soreness",
    ]
    private static let personalContextTerms = ["我", "我的", "自己", "i ", "i'", "my ", "me "]
    private static let personalActionTerms = [
        "记录", "记一下", "保存", "打卡", "估算", "估一估", "安排", "plan", "log", "estimate", "track",
    ]
    private static let analysisIntentTerms = [
        "分析", "解读", "总结", "趋势", "状态", "怎么样", "如何", "怎么", "是否", "多少", "多久",
        "为什么", "适合", "应该", "建议", "疲劳", "乏力", "要不要", "可以吗", "吗", "查看", "查询",
        "analyze", "analysis", "interpret", "trend", "how is", "how am", "how do", "should i", "can i",
    ]
    private static let followUpTerms = [
        "那我", "那今天", "那明天", "那昨天", "那前天", "那现在", "那这", "那它", "那如果",
        "这个", "这样", "刚才", "继续", "它", "这些", "上述", "前面说的", "相关吗",
        "what about", "and then", "that", "this", "those", "continue", "it ",
    ]
    private static let healthRetrievalIntentTerms = analysisIntentTerms + ["什么"]
    private static let personalRecordReferenceTerms = [
        "记录", "日志", "历史", "record", "records", "log", "logs", "history",
    ]
    private static let explicitHealthWriteTerms = [
        "帮我记录", "帮忙记录", "请记录", "我要记录", "我记录", "记录一下", "记一下",
        "保存", "打卡", "log my", "log ",
    ]
    // "状态" alone is too broad to identify a health request. These phrases
    // make common personal check-ins explicit without matching app/system state.
    private static let personalWellbeingEntityTerms = [
        "我的状态", "我今天的状态", "我今天状态", "我最近的状态", "我现在的状态",
        "身体状态", "健康状态", "精神状态", "精力状态",
    ]
    private static let nonHealthStateTerms = [
        "应用状态", "系统状态", "账号状态", "网络状态", "设备状态", "工作状态",
    ]
    private static let captureIntentTerms = [
        "记录", "记一下", "保存", "打卡", "估算", "估一估", "安排", "plan", "log", "estimate", "track",
        "吃了", "摄入", "安排训练", "训练计划",
    ]
    private static let readinessActivityTerms = [
        "跑", "训练", "运动", "锻炼", "健身", "游泳", "骑行", "骑车", "步行", "散步", "举铁", "练",
        "run", "running", "walk", "walking", "workout", "exercise", "train", "swim", "cycle", "cycling", "hike", "lift",
    ]
    private static let readinessQuestionTerms = [
        "能", "可以", "适合", "要不要", "该不该", "应该", "行不行", "吗", "不",
        "can i", "should i", "am i", "is it okay", "is it safe", "okay to", "safe to", "could i",
    ]

    static func shouldIncludeSummary(for userText: String, priorHealthContext: Bool = false) -> Bool {
        let normalized = userText.lowercased()
        if containsHealthEntity(in: normalized) {
            return personalContextTerms.contains(where: normalized.contains)
                || personalActionTerms.contains(where: normalized.contains)
                || healthRetrievalIntentTerms.contains(where: normalized.contains)
        }
        return priorHealthContext && isContextualFollowUp(normalized)
    }

    static func requiresHealthContext(for userText: String, priorHealthContext: Bool = false) -> Bool {
        requiresNarrative(for: userText, priorHealthContext: priorHealthContext)
            || requiresMealEstimationContext(for: userText)
            || (isPersonalHealthRecordLookup(userText.lowercased())
                && shouldIncludeSummary(for: userText, priorHealthContext: priorHealthContext))
    }

    static func requiresMealEstimationContext(for userText: String) -> Bool {
        let normalized = userText.lowercased()
        let asksForEstimate = ["估算", "估计", "估一估", "算一下", "calculate", "estimate"]
            .contains(where: normalized.contains)
        guard asksForEstimate else { return false }
        let mealTerms = [
            "午餐", "早餐", "晚餐", "加餐", "这顿", "这餐", "餐食", "食物",
            "meal", "lunch", "breakfast", "dinner", "snack", "food",
        ]
        if mealTerms.contains(where: normalized.contains) { return true }
        let nutritionTerms = ["蛋白质", "碳水", "脂肪", "营养", "protein", "carbohydrate", "nutrition", "macros"]
        let activityTerms = ["运动", "训练", "跑步", "锻炼", "消耗", "workout", "exercise", "run", "training", "expenditure"]
        return nutritionTerms.contains(where: normalized.contains)
            && !activityTerms.contains(where: normalized.contains)
    }

    static func hasPriorHealthContext(in priorUserMessages: [String]) -> Bool {
        for message in priorUserMessages.reversed() {
            let normalized = message.lowercased()
            // A logged measurement or meal is an action record, not a prior
            // health interpretation to which a vague follow-up should attach.
            if isCaptureIntent(normalized) { return false }
            if containsHealthEntity(in: normalized) { return true }
            guard isContextualFollowUp(normalized) else { return false }
        }
        return false
    }

    static func containsHealthEntity(in userText: String) -> Bool {
        let normalized = userText.lowercased()
        if healthEntityTerms.contains(where: { normalized.contains($0) })
            || isActivityReadinessQuestion(normalized) {
            return true
        }
        guard !nonHealthStateTerms.contains(where: { normalized.contains($0) }) else { return false }
        return personalWellbeingEntityTerms.contains(where: { normalized.contains($0) })
    }

    static func prompt(
        basePrompt: String,
        userText: String,
        summary: HealthContextSummary?,
        narrativeContext: HealthNarrativeContext? = nil,
        mealEstimationNutritionContext: MealEstimationNutritionContext? = nil,
        structuredNarrative: Bool = false,
        cloudHealthPolicy: CloudHealthContextPolicy? = nil,
        priorHealthContext: Bool = false
    ) -> String {
        guard shouldIncludeSummary(for: userText, priorHealthContext: priorHealthContext)
                || requiresMealEstimationContext(for: userText) else { return basePrompt }
        var prompt = basePrompt
        if requiresMealEstimationContext(for: userText) {
            if let mealEstimationNutritionContext,
               let data = try? encoded(mealEstimationNutritionContext),
               let json = String(data: data, encoding: .utf8) {
                prompt += """


                ## 餐食估算的本地营养参考
                以下只包含当天已记录营养估值、所有已记录餐食是否都有估值、饮食记录完成状态、最后一笔餐食的本地时间、营养目标和历史完整记录日聚合，不包含原始餐食记录或其他健康领域。allRecordedMealsHaveEvidence 只说明估值是否覆盖每笔已记录餐食，nutritionRecordStatus 只说明用户是否确认当天记录完整；两者不能互相推断。若任一状态不足，当天数值只覆盖有估值的已记录餐食；不得称为全天摄入，也不得与历史完整日均值直接比较。只有 mayCompareWithCompleteDayHistory 为 true 且 intakeAvailability 为 estimated 时才允许比较。不要把缺失值当成零，也不要据此给出健康诊断：
                \(json)
                """
            }
        } else if !structuredNarrative,
           let summary,
           let data = try? encoded(summary),
           let json = String(data: data, encoding: .utf8) {
            prompt += """


            ## 本地健康汇总（仅供回答当前健康数据问题）
            以下仅包含 7/28 日聚合、数据覆盖和可解析的建议引用；不得据此推断缺失值、生成诊断或编造指标：
            \(json)
            """
        }
        if let cloudHealthPolicy, !requiresMealEstimationContext(for: userText) {
            let restrictedClasses = CloudHealthContextPolicy.dataClasses
                .filter { !cloudHealthPolicy.allows($0) }
                .compactMap(\.healthContextTitle)
            if !restrictedClasses.isEmpty {
                prompt += """


                ## 云端健康数据授权边界
                当前未获准上传的健康类别：\(restrictedClasses.joined(separator: "、"))。不得从用户问题或其他数据推断这些类别的个人事实；用户询问未授权类别时，明确说明当前不能读取该类别，并只基于已授权的证据回答。
                """
            }
        }
        guard structuredNarrative,
              requiresNarrative(for: userText, priorHealthContext: priorHealthContext),
              let narrativeContext,
              let contextData = try? encoded(narrativeContext),
              let contextJSON = String(data: contextData, encoding: .utf8) else {
            return prompt
        }
        return """
        \(prompt)

        ## 健康解读结构（强制）
        只返回符合 response schema 的 JSON。使用 cloudHealthState、vitalTrends、activityTrends、aggregateSummary、subjectiveContext、evidence 和 recommendationCandidates 中可验证的信息；subjectiveContext 只代表用户本人报告的主观感受，不是 HealthKit 测量，不得混入客观健康状态。引用时必须明确标为用户自述。recommendations 只能选择 recommendationCandidates 中的 candidateID；本机将 ID 映射为已经验证的建议标题和证据，不能自行编写个性化建议。evidenceKeys 必须引用由本机状态、自述或推荐候选组成的 allowedEvidenceKeys。只保留能由引用支撑的判断；无证据支撑的领域应明确说明不足，不作推断。
        文本字段只写不含数值的自然语言，不得写数字、百分比、具体指标值或单位；数值和指标由界面从本机确定性 HealthState 渲染。不得诊断或猜测缺失数据。
        \(contextJSON)
        """
    }

    static func requiresNarrative(for userText: String, priorHealthContext: Bool = false) -> Bool {
        guard shouldIncludeSummary(for: userText, priorHealthContext: priorHealthContext) else { return false }
        let normalized = userText.lowercased()
        guard !isCaptureIntent(normalized) else { return false }
        return analysisIntentTerms.contains(where: normalized.contains)
            || (priorHealthContext && followUpTerms.contains(where: normalized.contains))
            || isActivityReadinessQuestion(normalized)
    }

    private static func isActivityReadinessQuestion(_ normalized: String) -> Bool {
        readinessActivityTerms.contains(where: normalized.contains)
            && readinessQuestionTerms.contains(where: normalized.contains)
    }

    private static func isContextualFollowUp(_ normalized: String) -> Bool {
        followUpTerms.contains(where: normalized.contains)
    }

    private static func isCaptureIntent(_ normalized: String) -> Bool {
        captureIntentTerms.contains(where: { normalized.contains($0) })
    }

    private static func isPersonalHealthRecordLookup(_ normalized: String) -> Bool {
        guard !explicitHealthWriteTerms.contains(where: normalized.contains),
              personalRecordReferenceTerms.contains(where: normalized.contains),
              healthEntityTerms.contains(where: normalized.contains) else {
            return false
        }
        return personalContextTerms.contains(where: normalized.contains)
            || ["查看", "查询", "看看", "回顾", "show", "view", "check"].contains(where: normalized.contains)
    }

    private static func encoded(_ summary: HealthContextSummary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(summary)
    }

    private static func encoded(_ context: HealthNarrativeContext) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(context)
    }

    private static func encoded(_ context: MealEstimationNutritionContext) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(context)
    }
}
