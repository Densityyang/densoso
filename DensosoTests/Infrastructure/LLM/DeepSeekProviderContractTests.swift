import XCTest
@testable import Densoso

@MainActor
final class DeepSeekProviderContractTests: XCTestCase {
    func testAnthropicRequestAndResponseContract() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [
                .response(
                    status: 200,
                    data: try Gate03FixtureLoader.data("deepseek-text-tool-response")
                )
            ]
        )
        let clock = TestProviderRetryClock()
        let logSink = RecordingProviderLogSink()
        let provider = DeepSeekProvider(
            credentialSource: TestCredentialSource(values: [.deepSeek: "secret-fixture-key"]),
            transport: transport,
            clock: clock,
            logSink: logSink,
            jitter: { _ in 0 }
        )

        let events = try await collect(provider.stream(request(deadline: clock.now().addingTimeInterval(45))))

        XCTAssertTrue(events.contains(.textDelta("我会先生成可检查的草稿。")))
        XCTAssertTrue(events.contains { event in
            guard case .toolCall(let call) = event else { return false }
            return call.name == "log_weight"
                && call.arguments.objectValue?["kilograms"]?.doubleValue == 62.5
        })
        XCTAssertTrue(events.contains { event in
            guard case .usage(let usage) = event else { return false }
            return usage.inputTokens == 120 && usage.outputTokens == 32
        })

        let requests = await transport.recordedRequests()
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-api-key"), "secret-fixture-key")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(sent.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((object["thinking"] as? [String: String])?["type"], "disabled")
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let schema = try XCTUnwrap(tools.first?["input_schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(logSink.recordedMetadata().count, 1)
        XCTAssertEqual(logSink.recordedMetadata().first?.provider, .deepSeek)
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

func collect(
    _ stream: AsyncThrowingStream<ProviderEvent, Error>
) async throws -> [ProviderEvent] {
    var events: [ProviderEvent] = []
    for try await event in stream { events.append(event) }
    try Task.checkCancellation()
    return events
}
