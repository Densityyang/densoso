import DensosoDomain
import XCTest
@testable import Densoso

@MainActor
final class QwenMealVisionProviderContractTests: XCTestCase {
    func testPinnedQwen37SnapshotUsesImageAndStructuredObservationContract() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [
                .response(
                    status: 200,
                    data: try Gate03FixtureLoader.data("qwen3.7-flash-2026-07-15-response")
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
        XCTAssertEqual(observation.modelVersion, "qwen3.7-flash-2026-07-15")
        XCTAssertEqual(observation.usage?.inputTokens, 320)
        XCTAssertEqual(QwenMealVisionProvider.model, "qwen3.7-flash-2026-07-15")
        XCTAssertEqual(QwenMealVisionProvider.requiredCapabilities, [.vision, .structuredOutput])
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-vl-key")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "qwen3.7-flash-2026-07-15")
        let responseFormat = try XCTUnwrap(object["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(jsonSchema["name"] as? String, "MealVisionObservation")
        XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertEqual(Set(required), Set([
            "labels", "preparationHints", "cookingMethod", "containerHint", "portionHint", "isOccluded",
        ]))
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let labelArray = try XCTUnwrap(properties["labels"] as? [String: Any])
        XCTAssertEqual(labelArray["maxItems"] as? Int, 8)
        let labelItem = try XCTUnwrap(labelArray["items"] as? [String: Any])
        XCTAssertEqual(labelItem["maxLength"] as? Int, 80)
        let preparationArray = try XCTUnwrap(properties["preparationHints"] as? [String: Any])
        let preparationItem = try XCTUnwrap(preparationArray["items"] as? [String: Any])
        XCTAssertEqual(preparationItem["enum"] as? [String], ["raw", "cooked", "unknown"])
        let cookingMethod = try XCTUnwrap(properties["cookingMethod"] as? [String: Any])
        XCTAssertEqual(cookingMethod["type"] as? [String], ["string", "null"])
        XCTAssertEqual(object["enable_thinking"] as? Bool, false)
        XCTAssertNil(object["tools"])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let image = try XCTUnwrap(content.first?["image_url"] as? [String: Any])
        XCTAssertTrue((image["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        let prompt = content.compactMap { $0["text"] as? String }.joined()
        XCTAssertTrue(prompt.contains("不得输出 foodID"))
    }

    func testRollingQwen37AliasDoesNotSatisfyPinnedSnapshot() async throws {
        let response = Data(
            #"{"model":"qwen3.7-flash","choices":[{"message":{"content":"{}"}}]}"#.utf8
        )
        let transport = ScriptedProviderHTTPTransport(steps: [.response(status: 200, data: response)])
        let provider = QwenMealVisionProvider(
            endpoint: endpoint,
            credentialSource: TestCredentialSource(values: [.qwen: "fixture"]),
            transport: transport,
            jitter: { _ in 0 }
        )

        do {
            _ = try await provider.analyze(imageJPEG: fixtureJPEG, locale: .current)
            XCTFail("Expected a non-pinned response model to be rejected")
        } catch {
            XCTAssertEqual(error as? ProviderError, .malformedResponse)
        }
    }

    func testVLMCannotReturnFoodIDOrNutritionTruth() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [
                .response(
                    status: 200,
                    data: try Gate03FixtureLoader.data("qwen3.7-flash-2026-07-15-forbidden-food-id")
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
