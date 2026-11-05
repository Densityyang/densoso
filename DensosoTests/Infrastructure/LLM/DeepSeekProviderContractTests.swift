import XCTest
@testable import Densoso

@MainActor
final class DeepSeekProviderContractTests: XCTestCase {
    func testPreSerializationConsentCheckStopsBeforeDeepSeekRequestIsSent() async throws {
        let transport = ScriptedProviderHTTPTransport(steps: [])
        let clock = TestProviderRetryClock()
        let provider = DeepSeekProvider(
            credentialSource: TestCredentialSource(values: [.deepSeek: "fixture"]),
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )
        var request = request(deadline: clock.now().addingTimeInterval(45))
        request.preSerializationGate = { _ in
            throw ProviderError.consentPolicyChanged(provider: .deepSeek)
        }

        do {
            _ = try await collect(provider.stream(request))
            XCTFail("A failed pre-serialization consent check must stop the provider request")
        } catch {
            XCTAssertEqual(error as? ProviderError, .consentPolicyChanged(provider: .deepSeek))
        }
        let recorded = await transport.recordedRequests()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testMissingKeyFailsBeforeNetworkOrUserContentIsSent() async throws {
        let transport = ScriptedProviderHTTPTransport(steps: [])
        let clock = TestProviderRetryClock()
        let provider = DeepSeekProvider(
            credentialSource: TestCredentialSource(values: [:]),
            transport: transport,
            clock: clock,
            logSink: RecordingProviderLogSink(),
            jitter: { _ in 0 }
        )

        do {
            _ = try await collect(provider.stream(request(deadline: clock.now().addingTimeInterval(45))))
            XCTFail("A missing API key must fail locally")
        } catch {
            XCTAssertEqual(error as? ProviderError, .configurationMissing(provider: .deepSeek))
        }
        let recorded = await transport.recordedRequests()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testResponsesAPIRequestAndStreamingToolContract() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [
                .response(
                    status: 200,
                    data: try Gate03FixtureLoader.data("deepseek-responses-stream", extension: "sse")
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

        let events = try await collect(
            provider.stream(request(deadline: clock.now().addingTimeInterval(45), thinking: .high))
        )

        XCTAssertTrue(events.contains(.textDelta("我会先生成可检查的草稿。")))
        XCTAssertTrue(events.contains { event in
            guard case .toolCall(let call) = event else { return false }
            return call.id == "tool_1"
                && call.name == "log_weight"
                && call.arguments.objectValue?["kilograms"]?.doubleValue == 62.5
        })
        XCTAssertTrue(events.contains { event in
            guard case .reasoning(let item) = event else { return false }
            let reasoningContent = item.objectValue?["content"]?.arrayValue
            return item.objectValue?["type"]?.stringValue == "reasoning"
                && reasoningContent?.first?.objectValue?["type"]?.stringValue == "reasoning_text"
                && reasoningContent?.first?.objectValue?["text"]?.stringValue == "private reasoning fixture"
                && item.objectValue?["encrypted_content"] == nil
                && item.objectValue?["summary"] == nil
        })
        XCTAssertTrue(events.contains { event in
            guard case .usage(let usage) = event else { return false }
            return usage.inputTokens == 120
                && usage.cachedInputTokens == 40
                && usage.outputTokens == 32
                && usage.reasoningTokens == 12
        })
        XCTAssertTrue(events.contains(.completed(.toolUse)))

        let requests = await transport.recordedRequests()
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.deepseek.com/responses")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer secret-fixture-key")
        let body = try XCTUnwrap(sent.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "deepseek-flash")
        XCTAssertEqual(object["max_output_tokens"] as? Int, 256)
        XCTAssertEqual(object["instructions"] as? String, "fixture")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["store"] as? Bool, false)
        XCTAssertEqual((object["reasoning"] as? [String: String])?["effort"], "high")
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["role"] as? String, "user")
        let messageContent = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(messageContent.first?["type"] as? String, "input_text")
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let schema = try XCTUnwrap(tools.first?["parameters"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(logSink.recordedMetadata().count, 1)
        XCTAssertEqual(logSink.recordedMetadata().first?.provider, .deepSeek)
    }

    func testCompletedTextAndIncompleteReasonsAreFailClosed() async throws {
        let textResponse = Data(
            """
            event: response.completed
            data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]}}

            """.utf8
        )
        let textEvents = try await collect(
            makeProvider(data: textResponse).stream(request(deadline: Date().addingTimeInterval(45)))
        )
        XCTAssertEqual(textEvents, [.textDelta("done"), .completed(.completed)])

        let maxTokensResponse = Data(
            """
            event: response.incomplete
            data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"function_call","call_id":"partial-tool","name":"log_weight","arguments":"not-json"}]}}

            """.utf8
        )
        let maxTokensEvents = try await collect(
            makeProvider(data: maxTokensResponse).stream(request(deadline: Date().addingTimeInterval(45)))
        )
        XCTAssertFalse(maxTokensEvents.contains { if case .toolCall = $0 { true } else { false } })
        XCTAssertTrue(maxTokensEvents.contains(.completed(.maxTokens)))

        let filteredResponse = Data(
            """
            event: response.incomplete
            data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"content_filter"},"output":[{"type":"function_call","call_id":"filtered-tool","name":"log_weight","arguments":"{}"}]}}

            """.utf8
        )
        var filteredEvents: [ProviderEvent] = []
        do {
            for try await event in makeProvider(data: filteredResponse).stream(
                request(deadline: Date().addingTimeInterval(45))
            ) {
                filteredEvents.append(event)
            }
            XCTFail("Content-filtered responses must be rejected")
        } catch {
            XCTAssertEqual(error as? ProviderError, .contentRejected)
        }
        XCTAssertFalse(filteredEvents.contains { if case .toolCall = $0 { true } else { false } })

        let unknownReasonResponse = Data(
            """
            event: response.incomplete
            data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"provider_changed_the_contract"},"output":[]}}

            """.utf8
        )
        do {
            _ = try await collect(
                makeProvider(data: unknownReasonResponse).stream(request(deadline: Date().addingTimeInterval(45)))
            )
            XCTFail("Unknown incomplete reasons must fail closed")
        } catch {
            XCTAssertEqual(error as? ProviderError, .malformedResponse)
        }

        let unknownStatusResponse = Data(
            """
            event: response.completed
            data: {"type":"response.completed","response":{"status":"future_status","output":[]}}

            """.utf8
        )
        do {
            _ = try await collect(
                makeProvider(data: unknownStatusResponse).stream(request(deadline: Date().addingTimeInterval(45)))
            )
            XCTFail("A response.completed event with an unknown payload status must fail closed")
        } catch {
            XCTAssertEqual(error as? ProviderError, .malformedResponse)
        }
    }

    func testImageStructuredOutputAndStatelessToolHistoryEncoding() async throws {
        let transport = ScriptedProviderHTTPTransport(
            steps: [
                .response(
                    status: 200,
                    data: try Gate03FixtureLoader.data("deepseek-responses-stream", extension: "sse")
                )
            ]
        )
        let clock = TestProviderRetryClock()
        let provider = DeepSeekProvider(
            credentialSource: TestCredentialSource(values: [.deepSeek: "fixture"]),
            transport: transport,
            clock: clock,
            jitter: { _ in 0 }
        )
        let image = ImageInput(
            mimeType: "image/jpeg",
            base64Data: Data([0xFF, 0xD8, 0xFF]).base64EncodedString(),
            detail: .high
        )
        let reasoning = JSONValue.object([
            "type": .string("reasoning"),
            "id": .string("same-process-only"),
            "content": .array([
                .object([
                    "type": .string("reasoning_text"),
                    "text": .string("supported continuation text"),
                ]),
            ]),
            "encrypted_content": .string("same-process-only"),
            "summary": .array([
                .object(["type": .string("summary_text"), "text": .string("unsupported")]),
            ]),
        ])
        let opaqueReasoning = JSONValue.object([
            "type": .string("reasoning"),
            "encrypted_content": .string("encrypted-only-reasoning"),
        ])
        let format = StructuredOutputFormat(
            name: "MealVisionIntent",
            schema: .object(properties: [:], required: [], additionalProperties: false)
        )
        let requestID = UUID()
        let request = ModelRequest(
            requestID: requestID,
            conversationID: UUID(),
            systemPrompt: "inspect image",
            messages: [
                ModelMessage(role: .user, content: [.text("辨认餐食"), .image(image)]),
                ModelMessage(
                    role: .assistant,
                    content: [
                        .reasoning(reasoning),
                        .reasoning(opaqueReasoning),
                        .toolCall(ToolCall(id: "tool_1", name: "log_weight", arguments: .object(["kilograms": .number(62.5)]))),
                    ]
                ),
                ModelMessage(role: .tool, content: [.toolResult(toolCallID: "tool_1", content: "草稿已待确认")]),
            ],
            tools: [LogWeightTool().definition],
            maxOutputTokens: 128,
            thinking: .low,
            responseFormat: format,
            deadline: clock.now().addingTimeInterval(45)
        )

        let events = try await collect(provider.stream(request))
        XCTAssertTrue(events.contains { event in
            guard case .usage(let usage) = event else { return false }
            return usage.requestID == requestID
                && usage.imageCount == 1
                && usage.attempt == 1
                && (usage.latencyMilliseconds ?? -1) >= 0
        })

        let requests = await transport.recordedRequests()
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.deepseek.com/responses")
        let body = try XCTUnwrap(sent.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "deepseek-flash")
        XCTAssertNotEqual(object["model"] as? String, "deepseek-v4-flash-vision-exp")
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let userParts = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(userParts[1]["type"] as? String, "input_image")
        XCTAssertEqual(userParts[1]["detail"] as? String, "high")
        XCTAssertTrue((userParts[1]["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        let reasoningInputs = input.filter { $0["type"] as? String == "reasoning" }
        XCTAssertEqual(reasoningInputs.count, 1, "Encrypted-only response reasoning must be omitted")
        let reasoningInput = try XCTUnwrap(reasoningInputs.first)
        XCTAssertEqual(Set(reasoningInput.keys), Set(["type", "content"]))
        let reasoningContent = try XCTUnwrap(reasoningInput["content"] as? [[String: Any]])
        XCTAssertEqual(reasoningContent.count, 1)
        XCTAssertEqual(reasoningContent.first?["type"] as? String, "reasoning_text")
        XCTAssertEqual(reasoningContent.first?["text"] as? String, "supported continuation text")
        XCTAssertEqual(input[2]["type"] as? String, "function_call")
        XCTAssertEqual(input[3]["type"] as? String, "function_call_output")
        let text = try XCTUnwrap(object["text"] as? [String: Any])
        let textFormat = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(textFormat["type"] as? String, "json_schema")
        XCTAssertEqual(textFormat["name"] as? String, "MealVisionIntent")
    }

    func testImageMustBeInUserMessageAndFailsBeforeNetwork() async throws {
        let transport = ScriptedProviderHTTPTransport(steps: [])
        let provider = DeepSeekProvider(
            credentialSource: TestCredentialSource(values: [.deepSeek: "fixture"]),
            transport: transport,
            logSink: RecordingProviderLogSink(),
            jitter: { _ in 0 }
        )
        let image = ImageInput(
            mimeType: "image/jpeg",
            base64Data: Data([0xFF, 0xD8, 0xFF]).base64EncodedString()
        )
        let request = ModelRequest(
            requestID: UUID(),
            conversationID: UUID(),
            systemPrompt: "fixture",
            messages: [
                ModelMessage(role: .user, text: "请看图"),
                ModelMessage(role: .assistant, content: [.image(image)]),
            ],
            tools: [],
            maxOutputTokens: 128,
            thinking: .none,
            deadline: Date().addingTimeInterval(45),
            preSerializationGate: { serialize in try serialize() },
            networkAttemptGate: {}
        )

        do {
            _ = try await collect(provider.stream(request))
            XCTFail("Images in assistant messages are rejected by the provider contract")
        } catch {
            XCTAssertEqual(error as? ProviderError, .schemaViolation(path: "messages.image.role"))
        }
        let recordedRequests = await transport.recordedRequests()
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testRetiredDeepSeekVisionCompatibilityAliasIsNotVisionCapable() {
        XCTAssertFalse(
            ProviderCapabilityCatalog
                .deepSeekCapabilities(
                    for: "deepseek-v4-flash-vision-exp",
                    endpoint: ProviderCapabilityCatalog.deepSeekResponsesEndpoint
                )
                .contains(.vision)
        )
    }

    private func request(deadline: Date, thinking: ThinkingPolicy = .none) -> ModelRequest {
        var request = ModelRequest(
            requestID: UUID(),
            conversationID: UUID(),
            systemPrompt: "fixture",
            messages: [ModelMessage(role: .user, text: "记录体重")],
            tools: [LogWeightTool().definition],
            maxOutputTokens: 256,
            thinking: thinking,
            deadline: deadline
        )
        request.preSerializationGate = { serialize in try serialize() }
        request.networkAttemptGate = {}
        return request
    }

    private func makeProvider(data: Data) -> DeepSeekProvider {
        DeepSeekProvider(
            credentialSource: TestCredentialSource(values: [.deepSeek: "fixture"]),
            transport: ScriptedProviderHTTPTransport(steps: [.response(status: 200, data: data)]),
            jitter: { _ in 0 }
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
