import Foundation

struct DeepSeekProvider: TextModelProvider {
    let descriptor: ProviderDescriptor
    private let endpoint: URL
    private let credentialSource: any ProviderCredentialSource
    private let executor: ProviderRequestExecutor
    private let logSink: any ProviderLogSink

    init(
        endpoint: URL = URL(string: "https://api.deepseek.com/anthropic/v1/messages")!,
        model: String = "deepseek-v4-flash",
        credentialSource: any ProviderCredentialSource = KeychainStore.shared,
        transport: any ProviderHTTPTransport = URLSessionProviderTransport(),
        clock: any ProviderRetryClock = SystemProviderRetryClock(),
        logSink: any ProviderLogSink = NoOpProviderLogSink(),
        jitter: @escaping @Sendable (Int) -> Double = { _ in Double.random(in: 0...0.25) }
    ) {
        self.endpoint = endpoint
        self.credentialSource = credentialSource
        self.logSink = logSink
        self.executor = ProviderRequestExecutor(
            transport: transport,
            clock: clock,
            jitter: jitter
        )
        self.descriptor = ProviderDescriptor(
            id: .deepSeek,
            model: model,
            capabilities: [.text, .toolCalling, .structuredOutput]
        )
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let startedAt = Date()
                do {
                    guard let key = try credentialSource.credential(for: .deepSeek),
                          !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderError.configurationMissing(provider: .deepSeek)
                    }
                    var urlRequest = URLRequest(url: endpoint)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
                    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    urlRequest.httpBody = try JSONEncoder().encode(
                        AnthropicRequest(request: request, model: descriptor.model)
                    )

                    let result = try await executor.execute(urlRequest, deadline: request.deadline)
                    logSink.record(
                        ProviderLogRedactor.metadata(
                            requestID: request.requestID,
                            provider: .deepSeek,
                            status: result.response.statusCode,
                            attempt: result.attempt,
                            latencyMilliseconds: Self.latencyMilliseconds(since: startedAt)
                        )
                    )
                    let response = try JSONDecoder().decode(AnthropicResponse.self, from: result.data)
                    if response.stopReason == "refusal" {
                        throw ProviderError.contentRejected
                    }
                    for block in response.content {
                        if block.type == "text", let text = block.text, !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        } else if block.type == "tool_use",
                                  let id = block.id,
                                  let name = block.name,
                                  let input = block.input {
                            continuation.yield(.toolCall(ToolCall(id: id, name: name, arguments: input)))
                        }
                    }
                    if let usage = response.usage {
                        continuation.yield(
                            .usage(
                                ProviderUsage(
                                    provider: .deepSeek,
                                    model: response.model ?? descriptor.model,
                                    capability: .text,
                                    inputTokens: usage.inputTokens ?? 0,
                                    outputTokens: usage.outputTokens ?? 0,
                                    audioSeconds: 0,
                                    attempt: result.attempt
                                )
                            )
                        )
                    }
                    continuation.yield(.completed(Self.stopReason(response.stopReason)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ProviderError.malformedResponse)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private static func stopReason(_ raw: String?) -> ProviderStopReason {
        switch raw {
        case "tool_use": .toolUse
        case "max_tokens": .maxTokens
        default: .completed
        }
    }

    private static func latencyMilliseconds(since start: Date) -> Int {
        let milliseconds = max(Date().timeIntervalSince(start) * 1_000, 0)
        return Int(min(milliseconds, Double(Int.max)))
    }
}

private struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]?
    let toolChoice: [String: String]?
    let thinking: [String: String]

    init(request: ModelRequest, model: String) {
        self.model = model
        self.maxTokens = request.maxOutputTokens
        self.system = request.systemPrompt
        self.messages = request.messages.map(AnthropicMessage.init)
        self.tools = request.tools.isEmpty ? nil : request.tools.map(AnthropicTool.init)
        self.toolChoice = request.tools.isEmpty ? nil : ["type": "auto"]
        self.thinking = ["type": request.thinking.rawValue]
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case tools
        case toolChoice = "tool_choice"
        case thinking
    }
}

private struct AnthropicMessage: Encodable {
    let role: String
    let content: [AnthropicContentBlock]

    init(_ message: ModelMessage) {
        role = message.role == .assistant ? "assistant" : "user"
        content = message.content.map(AnthropicContentBlock.init)
    }
}

private struct AnthropicContentBlock: Codable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: JSONValue?
    let toolUseID: String?
    let content: String?

    init(_ content: ModelContent) {
        switch content {
        case .text(let text):
            self.init(type: "text", text: text)
        case .toolCall(let call):
            self.init(type: "tool_use", id: call.id, name: call.name, input: call.arguments)
        case .toolResult(let toolCallID, let content):
            self.init(type: "tool_result", toolUseID: toolCallID, content: content)
        }
    }

    init(
        type: String,
        text: String? = nil,
        id: String? = nil,
        name: String? = nil,
        input: JSONValue? = nil,
        toolUseID: String? = nil,
        content: String? = nil
    ) {
        self.type = type
        self.text = text
        self.id = id
        self.name = name
        self.input = input
        self.toolUseID = toolUseID
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content
        case toolUseID = "tool_use_id"
    }
}

private struct AnthropicTool: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONSchemaNode

    init(_ schema: ToolSchema) {
        name = schema.name
        description = schema.description
        inputSchema = schema.parameters
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

private struct AnthropicResponse: Decodable {
    let model: String?
    let content: [AnthropicContentBlock]
    let stopReason: String?
    let usage: AnthropicUsage?

    enum CodingKeys: String, CodingKey {
        case model, content, usage
        case stopReason = "stop_reason"
    }
}

private struct AnthropicUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}
