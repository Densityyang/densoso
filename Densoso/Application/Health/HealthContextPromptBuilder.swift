import DensosoDomain
import Foundation

enum HealthContextPromptBuilder {
    static let promptVersion = NarrativePromptVersion.current

    private static let healthEntityTerms = [
        "睡眠", "睡得", "睡觉", "睡不着", "睡不好", "没睡好", "睡了", "入睡", "夜醒", "老醒", "失眠",
        "sleep", "slept", "sleeping", "insomnia",
        "饮食", "吃了", "吃什么", "进食", "早餐", "午餐", "晚餐", "食材", "营养", "蛋白质", "碳水",
        "热量", "卡路里", "摄入", "meal", "food", "nutrition", "protein", "carbohydrate", "calorie", "intake",
        "体重", "身高", "体脂", "腰围", "血压", "心率", "心率变异", "血糖", "体温", "身体指标",
        "weight", "body mass", "body fat", "blood pressure", "heart rate", "hrv", "blood sugar", "bmi",
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
        structuredNarrative: Bool = false,
        cloudHealthPolicy: CloudHealthContextPolicy? = nil,
        priorHealthContext: Bool = false
    ) -> String {
        guard shouldIncludeSummary(for: userText, priorHealthContext: priorHealthContext) else { return basePrompt }
        var prompt = basePrompt
        if let summary,
           let data = try? encoded(summary),
           let json = String(data: data, encoding: .utf8) {
            prompt += """


            ## 本地健康汇总（仅供回答当前健康数据问题）
            以下仅包含 7/28 日聚合、数据覆盖和可解析的建议引用；不得据此推断缺失值、生成诊断或编造指标：
            \(json)
            """
        }
        if let cloudHealthPolicy {
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
        只返回符合 response schema 的 JSON。使用 healthState、subjectiveContext、evidence 和 recommendationCandidates 中可验证的信息；subjectiveContext 只代表用户本人报告的主观感受，不是 HealthKit 测量，不得混入 HealthState。引用时必须明确标为用户自述。evidenceKeys 必须引用由本机状态、自述或推荐候选组成的 allowedEvidenceKeys，不得引用 recommendation ID。只保留能由引用支撑的判断；无证据支撑的领域应明确说明不足，不作推断。
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
}
