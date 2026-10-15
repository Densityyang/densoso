import DensosoDomain
import XCTest
@testable import Densoso

@MainActor
final class QwenMealVisionProviderContractTests: XCTestCase {
    func testImageRequestAndRestrictedObservationContract() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [
                .response(
                    status: 200,
                    data: try Gate03FixtureLoader.data("qwen3-vl-flash-response")
                )
            ]
        )
        let clock = TestProviderRetryClock()
        let provider = QwenMealVisionProvider(
            endpoint: endpoint,
            credentialSource: TestCredentialSource(values: [.qwen: "secret-vl-key"]),
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )

        let observation = try await provider.analyze(
            imageJPEG: fixtureJPEG,
            locale: Locale(identifier: "zh-CN")
        )

        XCTAssertEqual(observation.labels, ["红烧豆腐"])
        XCTAssertEqual(observation.preparationHints, [.cooked])
        XCTAssertEqual(observation.cookingMethod, "braise")
        XCTAssertEqual(observation.portionHint, "约200g")
        XCTAssertEqual(observation.usage?.inputTokens, 320)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-vl-key")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "qwen3-vl-flash")
        XCTAssertEqual((object["response_format"] as? [String: String])?["type"], "json_object")
        XCTAssertEqual(object["enable_thinking"] as? Bool, false)
        XCTAssertNil(object["tools"])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let image = try XCTUnwrap(content.first?["image_url"] as? [String: Any])
        XCTAssertTrue((image["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        let prompt = content.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(prompt.contains("不得输出 foodID"))
    }

    func testVLMCannotReturnFoodIDOrNutritionTruth() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [
                .response(
                    status: 200,
                    data: try Gate03FixtureLoader.data("qwen3-vl-forbidden-food-id")
                )
            ]
        )
        let provider = QwenMealVisionProvider(
            endpoint: endpoint,
            credentialSource: TestCredentialSource(values: [.qwen: "fixture"]),
            transport: transport,
            jitter: { _ in 0 }
        )

        do {
            _ = try await provider.analyze(imageJPEG: fixtureJPEG, locale: .current)
            XCTFail("Expected strict observation rejection")
        } catch {
            XCTAssertEqual(error as? ProviderError, .schemaViolation(path: "visionObservation"))
        }
    }

    private var endpoint: URL {
        URL(string: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")!
    }

    private var fixtureJPEG: Data { Data([0xFF, 0xD8, 0xFF, 0xD9]) }
}
