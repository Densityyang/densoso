import Foundation

/// One lossless representation for text produced by iPhone Speech, Watch
/// dictation, App Intents, or manual editing. It is intentionally a draft and
/// has no persistence or HealthKit side effect.
struct VoiceCommandEnvelope: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case iPhoneSpeechAnalyzer
        case iPhoneLegacySpeech
        case watchDictation
        case appIntent
        case manualText
    }

    let text: String
    let localeIdentifier: String
    let source: Source
    let capturedAt: Date

    init(
        text: String,
        locale: Locale = .current,
        source: Source,
        capturedAt: Date = Date()
    ) {
        self.text = text
        self.localeIdentifier = locale.identifier
        self.source = source
        self.capturedAt = capturedAt
    }
}

enum VoiceCommandKind: String, Equatable, Sendable {
    case mealDraft
    case workoutPlanDraft
    case strengthSetDraft
    case readOnlyQuery
    case unclassified
}

/// Deliberately small, deterministic classification before handing a draft to
/// the agent. The router never writes data or bypasses confirmation.
struct VoiceCommandRouter: Sendable {
    func route(_ envelope: VoiceCommandEnvelope) -> VoiceCommandKind {
        let text = envelope.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unclassified }

        if containsAny(text, ["做", "训练计划", "明天练", "5x5", "5×5"]) {
            return .workoutPlanDraft
        }
        if containsAny(text, ["补一组", "组", "次", "公斤", "kg", "重量"]) {
            return .strengthSetDraft
        }
        if containsAny(text, ["吃了", "早餐", "午餐", "晚餐", "加餐", "卡路里"]) {
            return .mealDraft
        }
        if containsAny(text, ["多少", "查询", "今天", "本周", "进度"]) {
            return .readOnlyQuery
        }
        return .unclassified
    }

    private func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }
}
