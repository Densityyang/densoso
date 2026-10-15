import XCTest
@testable import DensosoDomain

final class PackagedFoodProviderTests: XCTestCase {
    func testCoordinatorNormalizesBarcodeBeforeCallingProvider() async throws {
        let provider = RecordingProvider(result: PackagedFoodMatch(
            barcode: "6901234567890", displayName: "测试饮料", providerID: "fixture", attribution: "fixture"
        ))
        let result = try await PackagedFoodLookupCoordinator(provider: provider).lookup(barcode: "690-1234 567890")

        XCTAssertEqual(result?.barcode, "6901234567890")
        let recordedBarcode = await provider.lastBarcode()
        XCTAssertEqual(recordedBarcode, "6901234567890")
    }

    func testInvalidBarcodeNeverCallsProvider() async {
        let provider = RecordingProvider(result: nil)
        do {
            _ = try await PackagedFoodLookupCoordinator(provider: provider).lookup(barcode: "not a barcode")
            XCTFail("Expected invalid barcode")
        } catch {
            XCTAssertEqual(error as? PackagedFoodLookupError, .invalidBarcode)
        }
        let recordedBarcode = await provider.lastBarcode()
        XCTAssertNil(recordedBarcode)
    }
}

private actor RecordingProvider: PackagedFoodProvider {
    private var barcode: String?
    private let result: PackagedFoodMatch?

    init(result: PackagedFoodMatch?) { self.result = result }

    func lookup(barcode: String) async throws -> PackagedFoodMatch? {
        self.barcode = barcode
        return result
    }

    func lastBarcode() -> String? { barcode }
}
