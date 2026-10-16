import Foundation

enum AgentReasoningPolicy {
    static func forUserMessage(_ text: String) -> ThinkingPolicy {
        let normalized = text
            .precomposedStringWithCanonicalMapping
            .lowercased()

        if containsAny(normalized, ["备赛", "训练周期", "周期计划", "长期训练", "制定计划", "完整计划", "训练安排"]) {
            return .max
        }
        if containsAny(normalized, ["健康分析", "趋势分析", "恢复情况", "训练负荷", "怎么改善", "综合分析", "给我建议", "推荐我"]) {
            return .high
        }
        if containsAny(normalized, ["记录体重", "记下体重", "添加体重", "称重记录", "记录一下体重"]) {
            return .none
        }
        // Meal drafts and ordinary questions use the low-latency reasoning budget.
        return .low
    }

    private static func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains(where: { text.contains($0) })
    }
}
