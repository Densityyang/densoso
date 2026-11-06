import Foundation
import XCTest
@testable import Densoso

final class IntelligenceRoutingPolicyTests: XCTestCase {
    private let policy = IntelligenceRoutingPolicy()

    func testLocalOnlyUsesOnDeviceModelWhenAvailable() {
        let capabilities = PlatformCapabilities(onDeviceLanguageModelAvailable: true, modernSpeechAvailable: true)
        XCTAssertEqual(policy.path(for: .localOnly, capabilities: capabilities), .localOnDevice)
    }

    func testLocalOnlyFallsBackToManualWhenModelUnavailable() {
        let capabilities = PlatformCapabilities(onDeviceLanguageModelAvailable: false, modernSpeechAvailable: true)
        XCTAssertEqual(policy.path(for: .localOnly, capabilities: capabilities), .manual)
    }

    func testCloudRequiresExplicitCloudMode() {
        let capabilities = PlatformCapabilities(onDeviceLanguageModelAvailable: true, modernSpeechAvailable: true)
        XCTAssertEqual(policy.path(for: .cloudDeepSeek, capabilities: capabilities), .cloudDeepSeek)
        XCTAssertEqual(policy.path(for: .cloudQwen, capabilities: capabilities), .cloudQwen)
    }

    @MainActor
    func testDefaultModeIsCloudDeepSeek() {
        XCTAssertEqual(IntelligencePreferences.defaultMode, .cloudDeepSeek)
        XCTAssertTrue(DeepSeekProvider().descriptor.capabilities.contains(.vision))
    }

    func testDeepSeekVisionCapabilityIsScopedToDocumentedModelAndEndpoint() {
        XCTAssertTrue(
            ProviderCapabilityCatalog
                .deepSeekCapabilities(
                    for: ProviderCapabilityCatalog.deepSeekFlashModel,
                    endpoint: ProviderCapabilityCatalog.deepSeekResponsesEndpoint
                )
                .contains(.vision)
        )
        XCTAssertFalse(
            ProviderCapabilityCatalog
                .deepSeekCapabilities(
                    for: "unconfigured-deepseek-model",
                    endpoint: ProviderCapabilityCatalog.deepSeekResponsesEndpoint
                )
                .contains(.vision)
        )
        XCTAssertFalse(
            ProviderCapabilityCatalog
                .deepSeekCapabilities(
                    for: ProviderCapabilityCatalog.deepSeekFlashModel,
                    endpoint: URL(string: "https://unconfigured-endpoint.example/responses")!
                )
                .contains(.vision)
        )
    }

    func testSpeechUsesLegacyBackendWhenModernSpeechIsUnavailable() {
        XCTAssertEqual(SpeechRoutingPolicy().backend(modernSpeechAvailable: false), .legacySpeechRecognizer)
    }

    func testSpeechUsesAnalyzerWhenModernSpeechIsAvailable() {
        XCTAssertEqual(SpeechRoutingPolicy().backend(modernSpeechAvailable: true), .speechAnalyzer)
    }

    func testPhase3QwenEnablesTextButNotVisionOrSpeech() {
        XCTAssertTrue(ProviderCapabilityCatalog.qwenAvailable.contains(.vision))
        XCTAssertTrue(ProviderCapabilityCatalog.qwenAvailable.contains(.speech))
        XCTAssertFalse(ProviderCapabilityCatalog.phase3Enabled.contains(.vision))
        XCTAssertFalse(ProviderCapabilityCatalog.phase3Enabled.contains(.speech))
        XCTAssertTrue(ProviderCapabilityCatalog.phase3Enabled.contains(.text))
        XCTAssertTrue(ModelStudioRegion.beijing.phase3Capabilities.contains(.toolCalling))
        XCTAssertFalse(ModelStudioRegion.singapore.phase3Capabilities.contains(.toolCalling))
    }
}
