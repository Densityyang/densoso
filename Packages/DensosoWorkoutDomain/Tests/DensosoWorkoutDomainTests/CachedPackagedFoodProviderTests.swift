import XCTest
@testable import DensosoWorkoutDomain

final class CachedPackagedFoodProviderTests: XCTestCase {
    func testCachedResultWorksOfflineWithoutSecondNetworkCall() async throws {
        let upstream = CountingProvider(result: .init(barcode: "6901234567890", displayName: "测试饮料", providerID: "fixture"))
        let provider = CachedPackagedFoodProvider(upstream: upstream, minimumInterval: 60)
        _ = try await provider.lookup(barcode: "6901234567890")
        await provider.setOnline(false)
        let cached = try await provider.lookup(barcode: "6901234567890")
        let calls = await upstream.callCount()
        XCTAssertEqual(cached?.displayName, "测试饮料")
        XCTAssertEqual(calls, 1)
    }

    func testOfflineCacheMissDoesNotCallUpstream() async {
        let upstream = CountingProvider(result: nil)
        let provider = CachedPackagedFoodProvider(upstream: upstream, isOnline: false)
        do {
            _ = try await provider.lookup(barcode: "6901234567890")
            XCTFail("Expected offline cache miss")
        } catch {
            XCTAssertEqual(error as? PackagedFoodProviderError, .offlineWithoutCache)
        }
        let calls = await upstream.callCount()
        XCTAssertEqual(calls, 0)
    }
}

private actor CountingProvider: PackagedFoodProvider {
    private let result: PackagedFoodMatch?
    private var calls = 0

    init(result: PackagedFoodMatch?) { self.result = result }
    func lookup(barcode: String) async throws -> PackagedFoodMatch? { calls += 1; return result }
    func callCount() -> Int { calls }
}
