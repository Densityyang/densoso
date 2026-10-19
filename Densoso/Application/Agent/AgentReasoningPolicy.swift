import Foundation

enum AgentReasoningPolicy {
    static func forUserMessage(_ text: String) -> ThinkingPolicy {
        let normalized = text
            .precomposedStringWithCanonicalMapping
            .lowercased()

        if containsAny(normalized, ["提取意图", "识别意图", "意图分类", "分类意图", "解析请求意图", "只提取意图"]) {
            return .none
        }
        if containsAny(normalized, [
            "备赛", "训练周期", "周期计划", "长期训练", "长期计划", "多周计划",
            "多日训练计划", "月度计划", "四周计划", "4周计划", "八周计划", "8周计划",
            "制定训练计划", "制定计划", "完整计划", "训练计划",
        ]) {
            return .max
        }
        if containsAny(normalized, [
            "健康分析", "趋势分析", "恢复情况", "训练负荷", "怎么改善", "综合分析",
            "给我建议", "推荐我", "今天怎么安排", "今天怎么练", "明天怎么练",
            "今天训练安排", "每日建议", "日常建议", "建议怎么吃", "应该怎么安排",
            "该如何安排", "下一步建议", "推荐训练", "推荐饮食",
        ]) {
            return .high
        }
        if containsAny(normalized, [
            "记录体重", "记下体重", "添加体重", "称重记录", "记录一下体重", "称一下体重",
        ]) {
            return .none
        }
        // Meal drafts and ordinary questions use the low-latency reasoning budget.
        return .low
    }

    private static func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains(where: { text.contains($0) })
    }
}
