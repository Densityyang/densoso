import XCTest
@testable import Densoso

@MainActor
final class QwenProviderContractTests: XCTestCase {
    func testOpenAICompatibleRequestAndResponseContract() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [
                .response(
                    status: 200,
                    data: try Gate03FixtureLoader.data("qwen-text-tool-response")
                )
            ]
        )
        let clock = TestProviderRetryClock()
        let endpoint = URL(string: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")!
        let provider = QwenProvider(
            endpoint: endpoint,
            credentialSource: TestCredentialSource(values: [.qwen: "secret-qwen-key"]),
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )

        let events = try await collect(provider.stream(request(deadline: clock.now().addingTimeInterval(45))))

        XCTAssertTrue(events.contains(.textDelta("我会先生成可检查的草稿。")))
        XCTAssertTrue(events.contains { event in
            guard case .toolCall(let call) = event else { return false }
            return call.name == "log_weight"
        })
        let requests = await transport.recordedRequests()
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer secret-qwen-key")
        let body = try XCTUnwrap(sent.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["enable_thinking"] as? Bool, false)
        XCTAssertEqual(object["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(object["stream"] as? Bool, false)
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
    }

    func testMalformedResponseIsRedactedAsTypedError() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [.response(status: 200, data: try Gate03FixtureLoader.data("malformed"))]
        )
        let clock = TestProviderRetryClock()
        let provider = QwenProvider(
            endpoint: URL(string: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")!,
            credentialSource: TestCredentialSource(values: [.qwen: "secret-qwen-key"]),
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )

        do {
            _ = try await collect(provider.stream(request(deadline: clock.now().addingTimeInterval(45))))
            XCTFail("Expected malformed response")
        } catch {
            XCTAssertEqual(error as? ProviderError, .malformedResponse)
            XCTAssertFalse(error.localizedDescription.contains("secret-qwen-key"))
        }
    }

    func testRegionWithoutFunctionCallingFailsLocallyBeforeNetwork() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [.response(status: 200, data: Data("{}".utf8))]
        )
        let clock = TestProviderRetryClock()
        let provider = QwenProvider(
            endpoint: URL(string: "https://workspace.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/chat/completions")!,
            capabilities: ModelStudioRegion.singapore.phase3Capabilities,
            credentialSource: TestCredentialSource(values: [.qwen: "secret-qwen-key"]),
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )

        do {
            _ = try await collect(provider.stream(request(deadline: clock.now().addingTimeInterval(45))))
            XCTFail("Expected local capability rejection")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unsupportedCapability(.toolCalling))
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 0)
    }

    func testRequestLargerThanConservativePricingTierFailsLocally() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [.response(status: 200, data: Data("{}".utf8))]
        )
        let provider = QwenProvider(
            endpoint: URL(string: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")!,
            credentialSource: TestCredentialSource(values: [.qwen: "secret-qwen-key"]),
            transport: transport,
            jitter: { _ in 0 }
        )
        let oversized = ModelRequest(
            requestID: UUID(),
            conversationID: UUID(),
            systemPrompt: nil,
            messages: [
                ModelMessage(
                    role: .user,
                    text: String(repeating: "a", count: QwenProvider.maximumPhase3RequestBytes)
                )
            ],
            tools: [],
            maxOutputTokens: 2_048,
            thinking: .disabled,
            deadline: Date().addingTimeInterval(45)
        )

        do {
            _ = try await collect(provider.stream(oversized))
            XCTFail("Expected local request limit")
        } catch {
            XCTAssertEqual(
                error as? ProviderError,
                .requestTooLarge(limitBytes: QwenProvider.maximumPhase3RequestBytes)
            )
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 0)
    }

    private func request(deadline: Date) -> ModelRequest {
        ModelRequest(
            requestID: UUID(),
            conversationID: UUID(),
            systemPrompt: "fixture",
            messages: [ModelMessage(role: .user, text: "记录体重")],
            tools: [LogWeightTool().definition],
            maxOutputTokens: 256,
            thinking: .disabled,
            deadline: deadline
        )
    }
}
