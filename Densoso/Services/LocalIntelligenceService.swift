import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// A privacy-preserving, on-device interpretation of a user utterance.
///
/// Suggestions are intentionally not persistence commands. They remain drafts
/// until a user completes a visible confirmation flow.
struct LocalIntelligenceResult: Equatable, Sendable {
    let reply: String
    let suggestion: LocalRecordSuggestion?
}

struct LocalRecordSuggestion: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case meal
        case workoutPlan = "workoutplan"
    }

    let kind: Kind
    let item: String
    let amount: String?
}

struct LocalRecordSuggestionParser: Sendable {
    func parse(
        category: String,
        item: String,
        amount: String,
        userText: String
    ) -> LocalRecordSuggestion? {
        guard let kind = LocalRecordSuggestion.Kind(rawValue: category.lowercased()) else { return nil }
        guard hasMatchingUserIntent(kind, in: userText) else { return nil }

        let normalizedItem = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedItem.isEmpty else { return nil }

        let normalizedAmount = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalRecordSuggestion(
            kind: kind,
            item: normalizedItem,
            amount: normalizedAmount.isEmpty ? nil : normalizedAmount
        )
    }

    private func hasMatchingUserIntent(_ kind: LocalRecordSuggestion.Kind, in userText: String) -> Bool {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        switch kind {
        case .meal:
            guard ![
                "没吃", "没有吃", "还没吃", "未吃", "didn't eat", "did not eat", "haven't eaten",
            ].contains(where: { text.contains($0) }) else { return false }
            return [
                "吃了", "吃过", "刚吃", "已经吃", "i ate", "i had", "had breakfast",
                "had lunch", "had dinner",
            ].contains(where: { text.contains($0) })
        case .workoutPlan:
            let isQuestion = ["吗", "么？", "适合", "是否", "可以", "能不能", "要不要", "should i", "can i"]
                .contains(where: { text.contains($0) })
            guard !isQuestion else { return false }
            let describesCompletedWorkout = [
                "完成了训练", "完成训练", "训练完成", "练完", "跑了", "跑步了", "跑完", "骑完", "游完",
                "做完运动", "今天训练了", "worked out", "finished my workout", "completed my workout",
                "i ran", "i trained",
            ].contains(where: { text.contains($0) })
            guard !describesCompletedWorkout else { return false }
            let futureIntent = [
                "训练计划", "锻炼计划", "计划", "打算", "准备", "想练", "安排", "明天练", "明天跑",
                "明天骑", "明天游", "明天走", "下周练", "下周跑", "plan to", "planning to",
                "schedule a", "tomorrow run", "tomorrow workout", "next week train",
            ].contains(where: { text.contains($0) })
            let workoutActivity = [
                "跑", "走", "步行", "骑", "游", "训练", "健身", "力量", "run", "walk", "ride", "cycle", "swim", "workout",
            ].contains(where: { text.contains($0) })
            return futureIntent && workoutActivity
        }
    }
}

@MainActor
@Observable
final class LocalIntelligenceService {
    enum LocalError: LocalizedError {
        case unavailable
        case unsupportedLocale

        var errorDescription: String? {
            switch self {
            case .unavailable: "On-device intelligence is not available on this device."
            case .unsupportedLocale: "The current app language is not supported by on-device intelligence."
            }
        }
    }

    nonisolated static var isSystemModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    func respond(to text: String, locale: Locale = .current) async throws -> String {
        try await extract(from: text, locale: locale).reply
    }

    func extract(from text: String, locale: Locale = .current) async throws -> LocalIntelligenceResult {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable else { throw LocalError.unavailable }
            guard model.supportsLocale(locale) else { throw LocalError.unsupportedLocale }
            let session = LanguageModelSession(
                instructions: """
                You are Densoso's on-device assistant. Respond in the user's language.
                Extract only a possible meal or explicitly future workout-plan suggestion from the user's text.
                Never classify a completed workout as a plan. Never estimate calories,
                invent quantities, claim that a meal, workout, or health record was saved, or perform a write.
                A visible user confirmation is always required before any record can be saved.
                """
            )
            let response = try await session.respond(to: text, generating: GeneratedLocalIntent.self)
            let content = response.content
            return LocalIntelligenceResult(
                reply: content.reply.trimmingCharacters(in: .whitespacesAndNewlines),
                suggestion: LocalRecordSuggestionParser().parse(
                    category: content.category,
                    item: content.item,
                    amount: content.amount,
                    userText: text
                )
            )
        }
        #endif
        throw LocalError.unavailable
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
private struct GeneratedLocalIntent {
    @Guide(description: "A concise reply in the user's language. State that any suggested record still needs visible confirmation.")
    var reply: String

    @Guide(description: "Exactly one of: meal, workoutPlan, or none. Use workoutPlan only for an explicit future plan, never for a completed workout.")
    var category: String

    @Guide(description: "The meal or workout name from the user text. Use an empty string when category is none or the name is unknown.")
    var item: String

    @Guide(description: "The quantity, serving, duration, sets, reps, or weight stated by the user. Use an empty string when not stated.")
    var amount: String
}
#endif
