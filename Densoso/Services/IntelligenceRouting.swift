import Foundation
import Speech

enum IntelligenceMode: String, CaseIterable, Sendable {
    case localOnly
    case cloudDeepSeek
}

enum IntelligencePath: Equatable, Sendable {
    case localOnDevice
    case cloudDeepSeek
    case manual
}

enum SpeechBackend: Equatable, Sendable {
    case speechAnalyzer
    case legacySpeechRecognizer
}

struct SpeechRoutingPolicy: Sendable {
    func backend(modernSpeechAvailable: Bool) -> SpeechBackend {
        modernSpeechAvailable ? .speechAnalyzer : .legacySpeechRecognizer
    }
}

struct PlatformCapabilities: Equatable, Sendable {
    let onDeviceLanguageModelAvailable: Bool
    let modernSpeechAvailable: Bool

    static var current: PlatformCapabilities {
        let modernSpeechAvailable: Bool
        if #available(iOS 26.0, *) {
            modernSpeechAvailable = SpeechTranscriber.isAvailable
        } else {
            modernSpeechAvailable = false
        }
        return PlatformCapabilities(
            onDeviceLanguageModelAvailable: LocalIntelligenceService.isSystemModelAvailable,
            modernSpeechAvailable: modernSpeechAvailable
        )
    }
}

struct IntelligenceRoutingPolicy: Sendable {
    func path(for mode: IntelligenceMode, capabilities: PlatformCapabilities) -> IntelligencePath {
        switch mode {
        case .cloudDeepSeek:
            .cloudDeepSeek
        case .localOnly:
            capabilities.onDeviceLanguageModelAvailable ? .localOnDevice : .manual
        }
    }
}

@MainActor
@Observable
final class IntelligencePreferences {
    private static let modeKey = "intelligenceMode"

    var mode: IntelligenceMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    init() {
        mode = IntelligenceMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .localOnly
    }
}
