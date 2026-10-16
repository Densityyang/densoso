import Foundation

struct DeepSeekProvider: MultimodalModelProvider {
    let descriptor: ProviderDescriptor
    private let endpoint: URL
    private let credentialSource: any ProviderCredentialSource
    private let executor: ProviderRequestExecutor
    private let logSink: any ProviderLogSink

    init(
        endpoint: URL = URL(string: "https://api.deepseek.com/responses")!,
        model: String = "deepseek-flash",
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
            capabilities: [.text, .toolCalling, .structuredOutput, .vision, .reasoning, .streaming]
        )
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let startedAt = Date()
                do {
                    try validate(request)
                    guard let key = try credentialSource.credential(for: .deepSeek),
                          !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ProviderError.configurationMissing(provider: .deepSeek)
                    }
                    var urlRequest = URLRequest(url: endpoint)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    urlRequest.httpBody = try JSONEncoder().encode(
                        DeepSeekResponsesRequest(request: request, model: descriptor.model)
                    )

                    let result = try await executor.executeStream(urlRequest, deadline: request.deadline)
                    logSink.record(
                        ProviderLogRedactor.metadata(
                            requestID: request.requestID,
                            provider: .deepSeek,
                            status: result.response.statusCode,
                            attempt: result.attempt,
                            latencyMilliseconds: Self.latencyMilliseconds(since: startedAt)
                        )
                    )

                    var parser = ServerSentEventParser()
                    var didEmitText = false
                    var didFinish = false
                    for try await chunk in result.chunks {
                        try Task.checkCancellation()
                        for event in try parser.consume(chunk) {
                            let eventType = try Self.eventType(event)
                            switch eventType {
                            case "response.output_text.delta":
                                guard let delta = event.payload.objectValue?["delta"]?.stringValue else {
                                    throw ProviderError.malformedResponse
                                }
                                if !delta.isEmpty {
                                    didEmitText = true
                                    continuation.yield(.textDelta(delta))
                                }
                            case "response.refusal.delta":
                                throw ProviderError.contentRejected
                            case "response.completed":
                                let response = try Self.responsePayload(event.payload)
                                try Self.emitOutput(
                                    from: response,
                                    providerModel: descriptor.model,
                                    attempt: result.attempt,
                                    didEmitText: &didEmitText,
                                    continuation: continuation
                                )
                                continuation.yield(.completed(.completed))
                                didFinish = true
                            case "response.incomplete":
                                let response = try Self.responsePayload(event.payload)
                                try Self.emitOutput(
                                    from: response,
                                    providerModel: descriptor.model,
                                    attempt: result.attempt,
                                    didEmitText: &didEmitText,
                                    continuation: continuation
                                )
                                continuation.yield(.completed(.maxTokens))
                                didFinish = true
                            case "response.failed", "error":
                                throw Self.responseError(event.payload)
                            default:
                                break
                            }
                            if didFinish { break }
                        }
                        if didFinish { break }
                    }
                    if !didFinish {
                        for event in try parser.finish() {
                            if try Self.eventType(event) == "response.completed" {
                                let response = try Self.responsePayload(event.payload)
                                try Self.emitOutput(
                                    from: response,
                                    providerModel: descriptor.model,
                                    attempt: result.attempt,
                                    didEmitText: &didEmitText,
                                    continuation: continuation
                                )
                                continuation.yield(.completed(.completed))
                                didFinish = true
                            }
                        }
                    }
                    guard didFinish else { throw ProviderError.malformedResponse }
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

    private func validate(_ request: ModelRequest) throws {
        guard descriptor.capabilities.contains(.text) else {
            throw ProviderError.unsupportedCapability(.text)
        }
        if !request.tools.isEmpty && !descriptor.capabilities.contains(.toolCalling) {
            throw ProviderError.unsupportedCapability(.toolCalling)
        }
        if request.responseFormat != nil && !descriptor.capabilities.contains(.structuredOutput) {
            throw ProviderError.unsupportedCapability(.structuredOutput)
        }
        if request.messages.contains(where: { message in
            message.content.contains { if case .image = $0 { true } else { false } }
        }) && !descriptor.capabilities.contains(.vision) {
            throw ProviderError.unsupportedCapability(.vision)
        }
        if request.thinking != .none && !descriptor.capabilities.contains(.reasoning) {
            throw ProviderError.unsupportedCapability(.reasoning)
        }
    }

    private static func eventType(_ event: ServerSentEvent) throws -> String {
        if let type = event.type { return type }
        guard let type = event.payload.objectValue?["type"]?.stringValue else {
            throw ProviderError.malformedResponse
        }
        return type
    }

    private static func responsePayload(_ payload: JSONValue) throws -> [String: JSONValue] {
        guard let object = payload.objectValue else { throw ProviderError.malformedResponse }
        if let response = object["response"]?.objectValue { return response }
        // Some compatible endpoints send the response object as event data directly.
        return object
    }

    private static func emitOutput(
        from response: [String: JSONValue],
        providerModel: String,
        attempt: Int,
        didEmitText: inout Bool,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) throws {
        if response["status"]?.stringValue == "failed" {
            throw responseError(.object(response))
        }
        guard let output = response["output"] else { throw ProviderError.malformedResponse }
        guard case .array(let items) = output else { throw ProviderError.malformedResponse }
        var calls: [ToolCall] = []
        var reasoning: [JSONValue] = []
        var fallbackText = ""
        for item in items {
            guard let object = item.objectValue else { throw ProviderError.malformedResponse }
            switch object["type"]?.stringValue {
            case "function_call":
                guard let name = object["name"]?.stringValue,
                      let callID = object["call_id"]?.stringValue ?? object["id"]?.stringValue,
                      let rawArguments = object["arguments"] else {
                    throw ProviderError.malformedResponse
                }
                let arguments: JSONValue
                switch rawArguments {
                case .string(let text):
                    guard let data = text.data(using: .utf8),
                          let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                        throw ProviderError.malformedResponse
                    }
                    arguments = decoded
                case .object:
                    arguments = rawArguments
                default:
                    throw ProviderError.malformedResponse
                }
                calls.append(ToolCall(id: callID, name: name, arguments: arguments))
            case "reasoning":
                // Kept only in memory and supplied to the next tool round. It is redacted
                // by AgentSession before any conversation record is written to disk.
                reasoning.append(item)
            case "message":
                guard case .array(let content) = object["content"] ?? .array([]) else {
                    throw ProviderError.malformedResponse
                }
                for block in content {
                    guard let blockObject = block.objectValue else { throw ProviderError.malformedResponse }
                    switch blockObject["type"]?.stringValue {
                    case "output_text":
                        fallbackText += blockObject["text"]?.stringValue ?? ""
                    case "refusal":
                        throw ProviderError.contentRejected
                    default:
                        break
                    }
                }
            default:
                break
            }
        }
        if !didEmitText, !fallbackText.isEmpty {
            continuation.yield(.textDelta(fallbackText))
            didEmitText = true
        }
        for item in reasoning { continuation.yield(.reasoning(item)) }
        for call in calls { continuation.yield(.toolCall(call)) }

        if let usageObject = response["usage"]?.objectValue {
            continuation.yield(
                .usage(
                    ProviderUsage(
                        provider: .deepSeek,
                        model: response["model"]?.stringValue ?? providerModel,
                        capability: .text,
                        inputTokens: usageObject["input_tokens"]?.intValue ?? 0,
                        outputTokens: usageObject["output_tokens"]?.intValue ?? 0,
                        audioSeconds: 0,
                        attempt: attempt
                    )
                )
            )
        }
    }

    private static func responseError(_ payload: JSONValue) -> ProviderError {
        guard let object = payload.objectValue else { return .malformedResponse }
        let response = object["response"]?.objectValue ?? object
        let error = response["error"]?.objectValue ?? object["error"]?.objectValue ?? object
        let code = error["code"]?.stringValue ?? error["type"]?.stringValue ?? ""
        if code.localizedCaseInsensitiveContains("refusal")
            || code.localizedCaseInsensitiveContains("content_filter") {
            return .contentRejected
        }
        return .malformedResponse
    }

    private static func latencyMilliseconds(since start: Date) -> Int {
        let milliseconds = max(Date().timeIntervalSince(start) * 1_000, 0)
        return Int(min(milliseconds, Double(Int.max)))
    }
}

private struct DeepSeekResponsesRequest: Encodable {
    let model: String
    let maxOutputTokens: Int
    let input: [JSONValue]
    let instructions: String?
    let tools: [JSONValue]?
    let toolChoice: String?
    let parallelToolCalls: Bool
    let reasoning: JSONValue
    let text: JSONValue?
    let stream = true
    let store = false

    init(request: ModelRequest, model: String) throws {
        self.model = model
        self.maxOutputTokens = request.maxOutputTokens
        self.input = try Self.inputItems(request.messages)
        self.instructions = request.systemPrompt
        if request.tools.isEmpty {
            self.tools = nil
        } else {
            self.tools = try request.tools.map(Self.toolValue)
        }
        self.toolChoice = request.tools.isEmpty ? nil : "auto"
        self.parallelToolCalls = false
        self.reasoning = .object(["effort": .string(request.thinking.rawValue)])
        if let format = request.responseFormat {
            self.text = .object([
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string(format.name),
                    "schema": try Self.jsonValue(format.schema),
                    "strict": .boolean(format.strict),
                ]),
            ])
        } else {
            self.text = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, input, instructions, tools, reasoning, text, stream, store
        case maxOutputTokens = "max_output_tokens"
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
    }

    private static func inputItems(_ messages: [ModelMessage]) throws -> [JSONValue] {
        var result: [JSONValue] = []
        for message in messages {
            var messageContent: [JSONValue] = []
            func flushMessage() {
                guard !messageContent.isEmpty else { return }
                result.append(
                    .object([
                        "type": .string("message"),
                        "role": .string(message.role.rawValue),
                        "content": .array(messageContent),
                    ])
                )
                messageContent.removeAll(keepingCapacity: true)
            }
            for content in message.content {
                switch content {
                case .text(let text):
                    messageContent.append(.object(["type": .string("input_text"), "text": .string(text)]))
                case .image(let image):
                    guard message.role == .user,
                          ["image/jpeg", "image/png", "image/webp", "image/gif"].contains(image.mimeType.lowercased()),
                          Data(base64Encoded: image.base64Data) != nil else {
                        throw ProviderError.schemaViolation(path: "image")
                    }
                    let dataURL = "data:\(image.mimeType);base64,\(image.base64Data)"
                    messageContent.append(
                        .object([
                            "type": .string("input_image"),
                            "image_url": .string(dataURL),
                            "detail": .string(image.detail.rawValue),
                        ])
                    )
                case .toolCall(let call):
                    flushMessage()
                    let encodedArguments = try call.arguments.encodedData()
                    guard let arguments = String(data: encodedArguments, encoding: .utf8) else {
                        throw ProviderError.malformedResponse
                    }
                    result.append(
                        .object([
                            "type": .string("function_call"),
                            "call_id": .string(call.id),
                            "name": .string(call.name),
                            "arguments": .string(arguments),
                        ])
                    )
                case .toolResult(let callID, let output):
                    flushMessage()
                    result.append(
                        .object([
                            "type": .string("function_call_output"),
                            "call_id": .string(callID),
                            "output": .string(output),
                        ])
                    )
                case .reasoning(let item):
                    flushMessage()
                    guard case .object = item else { throw ProviderError.malformedResponse }
                    result.append(item)
                }
            }
            flushMessage()
        }
        return result
    }

    private static func toolValue(_ tool: ToolSchema) throws -> JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": try jsonValue(tool.parameters),
        ])
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

private struct ServerSentEvent {
    let type: String?
    let payload: JSONValue
}

private struct ServerSentEventParser {
    private var lineBuffer = Data()
    private var eventType: String?
    private var dataLines: [String] = []

    mutating func consume(_ chunk: Data) throws -> [ServerSentEvent] {
        lineBuffer.append(chunk)
        var events: [ServerSentEvent] = []
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            var lineData = Data(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            if lineData.last == 0x0D { lineData.removeLast() }
            guard let line = String(data: lineData, encoding: .utf8) else {
                throw ProviderError.malformedResponse
            }
            if let event = try consumeLine(line) { events.append(event) }
        }
        return events
    }

    mutating func finish() throws -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        if !lineBuffer.isEmpty {
            guard let line = String(data: lineBuffer, encoding: .utf8) else {
                throw ProviderError.malformedResponse
            }
            lineBuffer.removeAll(keepingCapacity: false)
            if let event = try consumeLine(line) { events.append(event) }
        }
        if let event = try dispatch() { events.append(event) }
        return events
    }

    private mutating func consumeLine(_ line: String) throws -> ServerSentEvent? {
        if line.isEmpty { return try dispatch() }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            eventType = Self.fieldValue(line)
        } else if line.hasPrefix("data:") {
            dataLines.append(Self.fieldValue(line))
        }
        return nil
    }

    private mutating func dispatch() throws -> ServerSentEvent? {
        defer {
            eventType = nil
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return nil }
        let data = Data(dataLines.joined(separator: "\n").utf8)
        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        return ServerSentEvent(type: eventType, payload: payload)
    }

    private static func fieldValue(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        let value = String(line[line.index(after: colon)...])
        return value.hasPrefix(" ") ? String(value.dropFirst()) : value
    }
}
