import Foundation

struct QwenProvider: TextModelProvider {
    static let maximumPhase3RequestBytes = 120_000

    let descriptor: ProviderDescriptor
    private let endpoint: URL
    private let credentialSource: any ProviderCredentialSource
    private let executor: ProviderRequestExecutor
    private let logSink: any ProviderLogSink

    init(
        endpoint: URL,
        model: String = "qwen-flash",
        capabilities: Set<ProviderCapability> = ProviderCapabilityCatalog.phase3Enabled,
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
            id: .qwen,
            model: model,
            capabilities: capabilities
        )
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let startedAt = Date()
                do {
                    guard descriptor.capabilities.contains(.text) else {
                        throw ProviderError.unsupportedCapability(.text)
                    }
                    guard request.tools.isEmpty || descriptor.capabilities.contains(.toolCalling) else {
                        throw ProviderError.unsupportedCapability(.toolCalling)
                    }
                    guard let key = try credentialSource.credential(for: .qwen),
                          !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderError.configurationMissing(provider: .qwen)
                    }
                    let body = try JSONEncoder().encode(
                        OpenAIRequest(request: request, model: descriptor.model)
                    )
                    guard body.count <= Self.maximumPhase3RequestBytes else {
                        throw ProviderError.requestTooLarge(limitBytes: Self.maximumPhase3RequestBytes)
                    }
                    var urlRequest = URLRequest(url: endpoint)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    urlRequest.httpBody = body

                    let result = try await executor.execute(urlRequest, deadline: request.deadline)
                    logSink.record(
                        ProviderLogRedactor.metadata(
                            requestID: request.requestID,
                            provider: .qwen,
                            status: result.response.statusCode,
                            attempt: result.attempt,
                            latencyMilliseconds: Self.latencyMilliseconds(since: startedAt)
                        )
                    )
                    let response = try JSONDecoder().decode(OpenAIResponse.self, from: result.data)
                    guard let choice = response.choices.first else {
                        throw ProviderError.malformedResponse
                    }
                    if choice.finishReason == "content_filter" {
                        throw ProviderError.contentRejected
                    }
                    if let text = choice.message.content, !text.isEmpty {
                        continuation.yield(.textDelta(text))
                    }
                    for call in choice.message.toolCalls ?? [] {
                        guard let data = call.function.arguments.data(using: .utf8),
                              let arguments = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                            throw ProviderError.malformedResponse
                        }
                        continuation.yield(
                            .toolCall(ToolCall(id: call.id, name: call.function.name, arguments: arguments))
                        )
                    }
                    if let usage = response.usage {
                        continuation.yield(
                            .usage(
                                ProviderUsage(
                                    provider: .qwen,
                                    model: response.model ?? descriptor.model,
                                    capability: .text,
                                    inputTokens: usage.promptTokens ?? 0,
                                    outputTokens: usage.completionTokens ?? 0,
                                    audioSeconds: usage.audioSeconds ?? 0,
                                    attempt: result.attempt
                                )
                            )
                        )
                    }
                    continuation.yield(.completed(Self.stopReason(choice.finishReason)))
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
        case "tool_calls": .toolUse
        case "length": .maxTokens
        default: .completed
        }
    }

    private static func latencyMilliseconds(since start: Date) -> Int {
        let milliseconds = max(Date().timeIntervalSince(start) * 1_000, 0)
        return Int(min(milliseconds, Double(Int.max)))
    }
}

private struct OpenAIRequest: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let tools: [OpenAITool]?
    let toolChoice: String?
    let parallelToolCalls: Bool
    let enableThinking: Bool
    let stream: Bool
    let maxTokens: Int

    init(request: ModelRequest, model: String) {
        self.model = model
        var messages = request.messages.map(OpenAIMessage.init)
        if let systemPrompt = request.systemPrompt {
            messages.insert(OpenAIMessage(role: "system", content: systemPrompt), at: 0)
        }
        self.messages = messages
        self.tools = request.tools.isEmpty ? nil : request.tools.map(OpenAITool.init)
        self.toolChoice = request.tools.isEmpty ? nil : "auto"
        self.parallelToolCalls = false
        self.enableThinking = false
        self.stream = false
        self.maxTokens = request.maxOutputTokens
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case enableThinking = "enable_thinking"
        case maxTokens = "max_tokens"
    }
}

private struct OpenAIMessage: Codable {
    let role: String
    let content: String?
    let toolCalls: [OpenAIToolCall]?
    let toolCallID: String?

    init(role: String, content: String? = nil, toolCalls: [OpenAIToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    init(_ message: ModelMessage) {
        let text = message.content.compactMap { content -> String? in
            if case .text(let value) = content { return value }
            return nil
        }.joined(separator: "\n")
        let calls = message.content.compactMap { content -> OpenAIToolCall? in
            guard case .toolCall(let call) = content else { return nil }
            let argumentData = try? call.arguments.encodedData()
            let arguments = argumentData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return OpenAIToolCall(
                id: call.id,
                type: "function",
                function: .init(name: call.name, arguments: arguments)
            )
        }
        if let result = message.content.compactMap({ content -> (String, String)? in
            if case .toolResult(let id, let value) = content { return (id, value) }
            return nil
        }).first {
            self.init(role: "tool", content: result.1, toolCallID: result.0)
        } else {
            self.init(
                role: message.role.rawValue,
                content: text.isEmpty ? nil : text,
                toolCalls: calls.isEmpty ? nil : calls
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

private struct OpenAITool: Encodable {
    let type = "function"
    let function: OpenAIFunctionSchema

    init(_ schema: ToolSchema) {
        function = OpenAIFunctionSchema(
            name: schema.name,
            description: schema.description,
            parameters: schema.parameters
        )
    }
}

private struct OpenAIFunctionSchema: Encodable {
    let name: String
    let description: String
    let parameters: JSONSchemaNode
}

private struct OpenAIToolCall: Codable {
    let id: String
    let type: String?
    let function: OpenAIFunctionCall
}

private struct OpenAIFunctionCall: Codable {
    let name: String
    let arguments: String
}

private struct OpenAIResponse: Decodable {
    let model: String?
    let choices: [OpenAIChoice]
    let usage: OpenAIUsage?
}

private struct OpenAIChoice: Decodable {
    let message: OpenAIMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

private struct OpenAIUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let audioSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case audioSeconds = "audio_seconds"
    }
}
