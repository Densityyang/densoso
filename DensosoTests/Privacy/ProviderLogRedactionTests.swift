import XCTest
@testable import Densoso

final class ProviderLogRedactionTests: XCTestCase {
    func testLogMetadataCannotContainCredentialsOrHealthText() throws {
        let secret = "sk-secret-should-never-appear"
        let healthText = "今天体重62.5kg并且午餐吃了红烧肉"
        let metadata = ProviderLogRedactor.metadata(
            requestID: UUID(),
            provider: .deepSeek,
            status: 429,
            attempt: 2,
            latencyMilliseconds: 120,
            providerCode: "\(secret) \(healthText)"
        )
        let encoded = String(data: try JSONEncoder().encode(metadata), encoding: .utf8)!

        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains(healthText))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("transcript"))
        XCTAssertTrue(encoded.contains("redacted"))
    }

    func testProviderErrorsNeverIncludeResponseBodies() {
        let error = ProviderError.server(status: 503)
        XCTAssertFalse(error.localizedDescription.contains("response body"))
        XCTAssertFalse(error.localizedDescription.contains("sk-"))
    }
}
