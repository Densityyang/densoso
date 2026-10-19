import DensosoDomain
import Foundation

enum HealthNarrativePolicy {
    static func responseFormat(allowedEvidenceKeys: [String]) -> StructuredOutputFormat {
        let keySchema: JSONSchemaNode = allowedEvidenceKeys.isEmpty
            ? .string(maximumLength: 0)
            : .string(allowedValues: allowedEvidenceKeys)
        return StructuredOutputFormat(
            name: "health_narrative",
            schema: .object(
                properties: [
                    "headline": .string(minimumLength: 1, maximumLength: 100),
                    "summary": .string(minimumLength: 1, maximumLength: 500),
                    "recommendations": .array(
                        items: .string(minimumLength: 1, maximumLength: 180),
                        maximumItems: 4
                    ),
                    "tomorrowGuidance": .anyOf([
                        .string(maximumLength: 240),
                        .null,
                    ]),
                    "evidenceKeys": .array(items: keySchema, minimumItems: 1, maximumItems: 12),
                ],
                required: ["headline", "summary", "recommendations", "tomorrowGuidance", "evidenceKeys"],
                additionalProperties: false
            )
        )
    }

    static func decode(_ source: String, allowedEvidenceKeys: Set<String>) -> HealthNarrative? {
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["headline", "summary", "recommendations", "tomorrowGuidance", "evidenceKeys"],
              let narrative = try? JSONDecoder().decode(HealthNarrative.self, from: data),
              isValid(narrative, allowedEvidenceKeys: allowedEvidenceKeys) else {
            return nil
        }
        return narrative
    }

    static func isValid(_ narrative: HealthNarrative, allowedEvidenceKeys: Set<String>) -> Bool {
        let headline = narrative.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = narrative.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty, headline.count <= 100,
              !summary.isEmpty, summary.count <= 500,
              narrative.recommendations.count <= 4,
              narrative.recommendations.allSatisfy({
                  let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !value.isEmpty && value.count <= 180 && isNarrativeTextSafe(value)
              }),
              narrative.tomorrowGuidance.map({ $0.count <= 240 && isNarrativeTextSafe($0) }) ?? true,
              isNarrativeTextSafe(headline), isNarrativeTextSafe(summary),
              !narrative.evidenceKeys.isEmpty,
              narrative.evidenceKeys.count <= 12,
              Set(narrative.evidenceKeys).count == narrative.evidenceKeys.count,
              Set(narrative.evidenceKeys).isSubset(of: allowedEvidenceKeys) else {
            return false
        }
        return true
    }

    static func displayText(_ narrative: HealthNarrative) -> String {
        var lines = [narrative.headline, narrative.summary]
        lines.append(contentsOf: narrative.recommendations.map { "• \($0)" })
        if let guidance = narrative.tomorrowGuidance, !guidance.isEmpty {
            lines.append("明日：\(guidance)")
        }
        return lines.joined(separator: "\n\n")
    }

    static func deterministicFallback(_ context: HealthNarrativeContext?) -> String {
        guard let context, context.aggregateSummary != nil, let state = context.healthState else {
            return "目前没有可用的本地健康数据；数据空缺不代表零，我不会据此猜测。"
        }
        guard !context.allowedEvidenceKeys.isEmpty else {
            return "目前缺少可引用的健康证据，暂不生成个性化解读；数据空缺不代表零。"
        }
        let summary: String
        switch state.recovery.status {
        case .insufficientEvidence:
            summary = "目前可用的健康证据不足以判断恢复情况；数据空缺不代表零。"
        case .withinTypicalRange:
            summary = "目前可用的恢复证据大致处于个人近期常见范围。这不是医学判断。"
        case .attention:
            summary = "目前有可用证据提示恢复状态需要留意。这不是医学判断。"
        }
        let safeTitles = context.recommendationCandidates
            .filter { context.allowedEvidenceKeys.contains($0.evidenceKey) }
            .map(\.title)
            .filter(isNarrativeTextSafe)
            .prefix(2)
            .map { "• \($0)" }
        return ([summary] + safeTitles).joined(separator: "\n\n")
    }

    private static func isNarrativeTextSafe(_ text: String) -> Bool {
        text.range(of: #"[\p{N}%％]|(?i:\b(?:kcal|calories?|kg|bpm|hrv|rhr|steps?|minutes?)\b)|千卡|公斤|步数|分钟|心率变异性|静息心率"#, options: .regularExpression) == nil
    }
}
