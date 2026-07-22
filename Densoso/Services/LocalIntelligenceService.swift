import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

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
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable else { throw LocalError.unavailable }
            guard model.supportsLocale(locale) else { throw LocalError.unsupportedLocale }
            let session = LanguageModelSession(
                instructions: "You are Densoso's on-device assistant. Respond in the user's language. Never claim that a meal, workout, or health record was saved. Explain that records require a visible user confirmation."
            )
            return try await session.respond(to: text).content
        }
        #endif
        throw LocalError.unavailable
    }
}
