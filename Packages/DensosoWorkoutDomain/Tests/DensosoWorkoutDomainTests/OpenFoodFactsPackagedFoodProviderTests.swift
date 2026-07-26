import Foundation
import XCTest
@testable import DensosoWorkoutDomain

final class OpenFoodFactsPackagedFoodProviderTests: XCTestCase {
    func testMapsProductAndSendsRequiredAttributionHeaders() async throws {
        let client = RecordingHTTPClient(
            statusCode: 200,
            body: """
            {"status":1,"code":"6901234567890","product":{"product_name":"测试饮料","serving_quantity":"330","nutriments":{"energy-kcal_100g":42}}}
            """
        )
        let provider = try OpenFoodFactsPackagedFoodProvider(userAgent: "Densoso/1.0 (support@example.com)", client: client)

        let result = try await provider.lookup(barcode: "6901234567890")

        XCTAssertEqual(result?.displayName, "测试饮料")
        XCTAssertEqual(result?.servingGrams, 330)
        XCTAssertEqual(result?.caloriesPer100Grams, 42)
        XCTAssertEqual(result?.providerID, OpenFoodFactsPackagedFoodProvider.providerID)
        XCTAssertEqual(result?.attribution, OpenFoodFactsPackagedFoodProvider.defaultAttribution)
        let request = await client.lastRequest()
        XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"), "Densoso/1.0 (support@example.com)")
        XCTAssertTrue(request?.url?.absoluteString.contains("api/v2/product/6901234567890.json") == true)
    }

    func testNoProductReturnsNil() async throws {
        let provider = try OpenFoodFactsPackagedFoodProvider(
            userAgent: "Densoso/1.0",
            client: RecordingHTTPClient(statusCode: 200, body: "{\"status\":0}")
        )

        let result = try await provider.lookup(barcode: "6901234567890")
        XCTAssertNil(result)
    }

    func testRejectsMismatchedProductBarcode() async throws {
        let provider = try OpenFoodFactsPackagedFoodProvider(
            userAgent: "Densoso/1.0",
            client: RecordingHTTPClient(statusCode: 200, body: "{\"status\":1,\"code\":\"12345678\",\"product\":{\"product_name\":\"错误商品\"}}")
        )

        await XCTAssertThrowsErrorAsync(try await provider.lookup(barcode: "6901234567890")) { error in
            XCTAssertEqual(error as? OpenFoodFactsError, .barcodeMismatch)
        }
    }

    func testMaps429AndServerFailureWithoutParsingProduct() async throws {
        let rateLimited = try OpenFoodFactsPackagedFoodProvider(userAgent: "Densoso/1.0", client: RecordingHTTPClient(statusCode: 429, body: "{}"))
        let unavailable = try OpenFoodFactsPackagedFoodProvider(userAgent: "Densoso/1.0", client: RecordingHTTPClient(statusCode: 503, body: "{}"))

        await XCTAssertThrowsErrorAsync(try await rateLimited.lookup(barcode: "6901234567890")) { error in
            XCTAssertEqual(error as? OpenFoodFactsError, .rateLimited)
        }
        await XCTAssertThrowsErrorAsync(try await unavailable.lookup(barcode: "6901234567890")) { error in
            XCTAssertEqual(error as? OpenFoodFactsError, .serviceUnavailable(statusCode: 503))
        }
    }

    func testRequiresNonEmptyUserAgent() {
        XCTAssertThrowsError(try OpenFoodFactsPackagedFoodProvider(userAgent: "   ")) { error in
            XCTAssertEqual(error as? OpenFoodFactsError, .missingUserAgent)
        }
    }
}

private actor RecordingHTTPClient: HTTPDataClient {
    private let statusCode: Int
    private let body: Data
    private var request: URLRequest?

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = Data(body.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    func lastRequest() -> URLRequest? { request }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error")
    } catch {
        errorHandler(error)
    }
}
