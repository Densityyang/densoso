import Foundation
import Speech

enum IntelligenceMode: String, CaseIterable, Sendable {
    case localOnly
    case cloudDeepSeek
    case cloudQwen
}

enum IntelligencePath: Equatable, Sendable {
    case localOnDevice
    case cloudDeepSeek
    case cloudQwen
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
        case .cloudQwen:
            .cloudQwen
        case .localOnly:
            capabilities.onDeviceLanguageModelAvailable ? .localOnDevice : .manual
        }
    }
}

@MainActor
protocol ProviderSelecting: AnyObject {
    func provider(for mode: IntelligenceMode) throws -> any TextModelProvider
}

@MainActor
final class ProviderRegistry: ProviderSelecting {
    private let credentialSource: any ProviderCredentialSource
    private let configuration: ProviderConfigurationPreferences
    private let transport: any ProviderHTTPTransport

    init(
        credentialSource: any ProviderCredentialSource = KeychainStore.shared,
        configuration: ProviderConfigurationPreferences,
        transport: any ProviderHTTPTransport = URLSessionProviderTransport()
    ) {
        self.credentialSource = credentialSource
        self.configuration = configuration
        self.transport = transport
    }

    func provider(for mode: IntelligenceMode) throws -> any TextModelProvider {
        switch mode {
        case .cloudDeepSeek:
            return DeepSeekProvider(
                credentialSource: credentialSource,
                transport: transport
            )
        case .cloudQwen:
            return QwenProvider(
                endpoint: try configuration.qwenEndpoint(),
                capabilities: configuration.qwenRegion.phase3Capabilities,
                credentialSource: credentialSource,
                transport: transport
            )
        case .localOnly:
            throw ProviderError.unsupportedCapability(.text)
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
