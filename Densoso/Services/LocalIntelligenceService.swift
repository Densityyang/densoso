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

struct LocalRecordSuggestion: Equatable, Sendable {
    enum Kind: String, Sendable {
        case meal
        case workout
    }

    let kind: Kind
    let item: String
    let amount: String?
}

struct LocalRecordSuggestionParser: Sendable {
    func parse(category: String, item: String, amount: String) -> LocalRecordSuggestion? {
        guard let kind = LocalRecordSuggestion.Kind(rawValue: category.lowercased()) else { return nil }

        let normalizedItem = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedItem.isEmpty else { return nil }

        let normalizedAmount = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalRecordSuggestion(
            kind: kind,
            item: normalizedItem,
            amount: normalizedAmount.isEmpty ? nil : normalizedAmount
        )
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
                Extract only a possible meal or workout draft from the user's text. Never estimate calories,
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
                    amount: content.amount
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

    @Guide(description: "Exactly one of: meal, workout, or none.")
    var category: String

    @Guide(description: "The meal or workout name from the user text. Use an empty string when category is none or the name is unknown.")
    var item: String

    @Guide(description: "The quantity, serving, duration, sets, reps, or weight stated by the user. Use an empty string when not stated.")
    var amount: String
}
#endif
