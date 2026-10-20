import XCTest
@testable import DensosoDomain

final class SharedErrorDescriptorTests: XCTestCase {
    func testStandardErrorCodesMatchMainPR109Contract() {
        XCTAssertEqual(SharedErrorCode.allCases.map(\.rawValue), [
            "NetworkUnavailable",
            "ProviderUnauthorized",
            "ProviderRateLimited",
            "ProviderUnavailable",
            "StructuredOutputInvalid",
            "ToolArgumentsInvalid",
            "HealthKitUnauthorized",
            "HealthKitUnavailable",
            "ProjectionFailed",
            "ConfirmationExpired",
            "ActionConflict",
            "WatchUnavailable",
            "WorkoutKitUnauthorized",
        ])
    }

    func testHealthKitDescriptorUsesGenericUserMessageAndHidesRawDetail() {
        let privateDetail = "sleep duration 7h 42m"
        let error = HealthStoreClientError.queryFailed(privateDetail)
        let descriptor = error.sharedErrorDescriptor

        XCTAssertEqual(descriptor.code, .healthKitUnavailable)
        XCTAssertEqual(descriptor.userMessage, "暂时没能更新今天的状态。")
        XCTAssertEqual(error.localizedDescription, descriptor.userMessage)
        XCTAssertTrue(descriptor.diagnosticSafeDetail.contains("reason=healthKitQueryFailed"))
        XCTAssertFalse(descriptor.diagnosticSafeDetail.contains(privateDetail))
        XCTAssertFalse(error.localizedDescription.contains(privateDetail))
    }

    func testWatchDescriptorHidesCollidingMessageIdentifier() {
        let privateMessageID = UUID(uuidString: "2cf2f913-0a56-41cb-a694-1209acafde83")!
        let error = WatchMessageError.messageIDCollision(privateMessageID)
        let descriptor = error.sharedErrorDescriptor

        XCTAssertEqual(descriptor.code, .watchUnavailable)
        XCTAssertEqual(error.localizedDescription, descriptor.userMessage)
        XCTAssertTrue(descriptor.diagnosticSafeDetail.contains("reason=watchMessageIDCollision"))
        XCTAssertFalse(descriptor.diagnosticSafeDetail.contains(privateMessageID.uuidString))
    }

    func testUnclassifiedErrorUsesSafeFallbackWithoutUnderlyingDescription() {
        let privateDetail = "private file path /Users/person/health-export.json"
        let error = PrivateDetailError(detail: privateDetail)
        let fallback = SharedErrorDescriptor.projectionFailedFallback

        let descriptor = SharedErrorDescriptor.mapped(from: error, fallback: fallback)

        XCTAssertEqual(descriptor, fallback)
        XCTAssertFalse(descriptor.userMessage.contains(privateDetail))
        XCTAssertFalse(descriptor.diagnosticSafeDetail.contains(privateDetail))
    }
}

private struct PrivateDetailError: LocalizedError {
    let detail: String

    var errorDescription: String? { detail }
}
