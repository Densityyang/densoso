import DensosoDomain
import Foundation

enum HealthContextPromptBuilder {
    private static let healthTerms = [
        "今日", "今天", "本周", "上周", "趋势", "睡眠", "体重", "活动量", "运动负荷",
        "训练", "运动", "活动", "步数", "心率", "hrv", "疲劳", "状态", "休息",
        "健康", "缺口", "摄入", "消耗", "heart", "sleep", "weight", "activity", "workout",
        "training", "fatigue", "trend", "calorie",
    ]
    private static let readinessActivityTerms = [
        "跑", "训练", "运动", "锻炼", "健身", "游泳", "骑行", "骑车", "步行", "散步", "举铁", "练",
        "run", "running", "walk", "walking", "workout", "exercise", "train", "swim", "cycle", "cycling", "hike", "lift",
    ]
    private static let readinessQuestionTerms = [
        "能", "可以", "适合", "要不要", "该不该", "应该", "行不行", "吗", "不",
        "can i", "should i", "am i", "is it okay", "is it safe", "okay to", "safe to", "could i",
    ]

    static func shouldIncludeSummary(for userText: String) -> Bool {
        let normalized = userText.lowercased()
        return healthTerms.contains { normalized.contains($0) }
            || isActivityReadinessQuestion(normalized)
    }

    static func prompt(
        basePrompt: String,
        userText: String,
        summary: HealthContextSummary?,
        narrativeContext: HealthNarrativeContext? = nil,
        structuredNarrative: Bool = false
    ) -> String {
        guard shouldIncludeSummary(for: userText) else { return basePrompt }
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
        guard structuredNarrative,
              requiresNarrative(for: userText),
              let narrativeContext,
              let contextData = try? encoded(narrativeContext),
              let contextJSON = String(data: contextData, encoding: .utf8) else {
            return prompt
        }
        return """
        \(prompt)

        ## 健康解读结构（强制）
        只返回符合 response schema 的 JSON。使用 healthState、evidence 和 recommendationCandidates 中可验证的信息；evidenceKeys 必须引用由本机状态证据或推荐候选证据键组成的 allowedEvidenceKeys，不得引用 recommendation ID。只保留能由引用支撑的判断；无证据支撑的领域应明确说明不足，不作推断。
        文本字段只写不含数值的自然语言，不得写数字、百分比、具体指标值或单位；数值和指标由界面从本机确定性 HealthState 渲染。不得诊断或猜测缺失数据。
        \(contextJSON)
        """
    }

    static func requiresNarrative(for userText: String) -> Bool {
        guard shouldIncludeSummary(for: userText) else { return false }
        let normalized = userText.lowercased()
        let captureTerms = ["记录", "记一下", "保存", "打卡", "吃了", "摄入", "安排训练", "训练计划"]
        guard !captureTerms.contains(where: normalized.contains) else { return false }
        let queryTerms = [
            "分析", "总结", "趋势", "状态", "怎么样", "如何", "是否", "多少", "多久",
            "为什么", "适合", "应该", "太累", "疲劳", "乏力", "要不要", "可以吗", "吗", "查看", "看看", "查询", "?", "？",
            "analyze", "trend", "how is", "how am", "should i",
        ]
        return queryTerms.contains(where: normalized.contains)
            || isActivityReadinessQuestion(normalized)
    }

    private static func isActivityReadinessQuestion(_ normalized: String) -> Bool {
        readinessActivityTerms.contains(where: normalized.contains)
            && readinessQuestionTerms.contains(where: normalized.contains)
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
