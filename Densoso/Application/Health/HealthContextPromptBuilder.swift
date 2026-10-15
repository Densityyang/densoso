import DensosoDomain
import Foundation

enum HealthContextPromptBuilder {
    private static let healthTerms = [
        "今日", "本周", "上周", "趋势", "睡眠", "体重", "活动量", "运动负荷",
        "健康", "缺口", "摄入", "消耗", "heart", "sleep", "weight", "activity",
        "workout", "trend", "calorie",
    ]

    static func shouldIncludeSummary(for userText: String) -> Bool {
        let normalized = userText.lowercased()
        return healthTerms.contains { normalized.contains($0) }
    }

    static func prompt(
        basePrompt: String,
        userText: String,
        summary: HealthContextSummary?
    ) -> String {
        guard shouldIncludeSummary(for: userText), let summary,
              let data = try? encoded(summary),
              let json = String(data: data, encoding: .utf8) else {
            return basePrompt
        }
        return """
        \(basePrompt)

        ## 本地健康汇总（仅供回答当前健康数据问题）
        以下仅包含 7/28 日聚合、数据覆盖和可解析的建议引用；不得据此推断缺失值、生成诊断或编造指标：
        \(json)
        """
    }

    private static func encoded(_ summary: HealthContextSummary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(summary)
    }
}
