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
    }
}
