import Foundation

/// DeepSeek API HTTP 客户端 —— Anthropic Messages API 格式
/// Base URL: https://api.deepseek.com/anthropic
/// Model: deepseek-v4-flash
/// Auth: x-api-key
final class DeepSeekClient {
    private let baseURL: String
    private let model: String
    private let session: URLSession

    init(
        baseURL: String = "https://api.deepseek.com/anthropic",
        model: String = "deepseek-v4-flash"
    ) {
        self.baseURL = baseURL
        self.model = model
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    private var apiKey: String? {
        try? KeychainStore.shared.readAPIKey()
    }

    // MARK: - Anthropic 请求/响应类型

    struct Request: Encodable {
        let model: String
        let maxTokens: Int
        let system: String?
        let messages: [Message]
        let tools: [ToolDef]?
        let toolChoice: ToolChoice?

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system, messages, tools
            case toolChoice = "tool_choice"
        }
    }

    enum ToolChoice: Encodable {
        case auto
        case any
        case tool(name: String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .auto: try container.encode(["type": "auto"])
            case .any:  try container.encode(["type": "any"])
            case .tool(let name): try container.encode(["type": "tool", "name": name])
            }
        }
    }

    struct ToolDef: Encodable {
        let name: String
        let description: String
        let inputSchema: JSONSchema

        enum CodingKeys: String, CodingKey {
            case name, description
            case inputSchema = "input_schema"
        }
    }

    struct JSONSchema: Encodable {
        let type: String
        let properties: [String: PropertySchema]?
        let required: [String]?

        init(type: String = "object", properties: [String: PropertySchema]? = nil, required: [String]? = nil) {
            self.type = type; self.properties = properties; self.required = required
        }
    }

    struct PropertySchema: Encodable {
        let type: String
        let description: String?
        let `enum`: [String]?
        let `default`: IntOrString?

        init(type: String, description: String? = nil, enum: [String]? = nil,
             default: IntOrString? = nil) {
            self.type = type; self.description = description; self.enum = `enum`
            self.default = `default`
        }
    }

    enum IntOrString: Encodable {
        case int(Int), string(String)
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self { case .int(let v): try c.encode(v); case .string(let v): try c.encode(v) }
        }
    }

    /// Anthropic Message（内容为文本或 content block 数组）
    struct Message: Codable {
        let role: String
        let content: ContentValue

        init(role: String, text: String) {
            self.role = role
            self.content = .text(text)
        }
        init(role: String, blocks: [ContentBlock]) {
            self.role = role
            self.content = .blocks(blocks)
        }
    }

    enum ContentValue: Codable {
        case text(String)
        case blocks([ContentBlock])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) { self = .text(str) }
            else if let blocks = try? container.decode([ContentBlock].self) { self = .blocks(blocks) }
            else { throw DecodingError.typeMismatch(ContentValue.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "expected String or [ContentBlock]")) }
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let str): try container.encode(str)
            case .blocks(let blocks): try container.encode(blocks)
            }
        }
    }

    struct ContentBlock: Codable {
        let type: String
        var text: String?
        var id: String?
        var name: String?
        var input: [String: AnyJSON]?
        var toolUseId: String?
        var content: AnyJSON?

        enum CodingKeys: String, CodingKey {
            case type, text, id, name, input, content
            case toolUseId = "tool_use_id"
        }
    }

    enum AnyJSON: Codable {
        case string(String), int(Int), double(Double), bool(Bool), array([AnyJSON]), object([String: AnyJSON]), null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let v = try? container.decode(String.self) { self = .string(v) }
            else if let v = try? container.decode(Int.self) { self = .int(v) }
            else if let v = try? container.decode(Double.self) { self = .double(v) }
            else if let v = try? container.decode(Bool.self) { self = .bool(v) }
            else if let v = try? container.decode([AnyJSON].self) { self = .array(v) }
            else if let v = try? container.decode([String: AnyJSON].self) { self = .object(v) }
            else { self = .null }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v); case .int(let v): try c.encode(v)
            case .double(let v): try c.encode(v); case .bool(let v): try c.encode(v)
            case .array(let v): try c.encode(v); case .object(let v): try c.encode(v)
            case .null: try c.encodeNil()
            }
        }

        var asString: String? { if case .string(let v) = self { return v }; return nil }
        var asInt: Int? { if case .int(let v) = self { return v }; return nil }
        var asDouble: Double? { if case .double(let v) = self { return v }; if case .int(let v) = self { return Double(v) }; return nil }
        var asBool: Bool? { if case .bool(let v) = self { return v }; return nil }
    }

    struct APIResponse: Decodable {
        let id: String?
        let model: String?
        let role: String?
        let content: [ContentBlock]
        let stopReason: String?
        let usage: Usage?

        enum CodingKeys: String, CodingKey {
            case id, model, role, content, usage
            case stopReason = "stop_reason"
        }
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    /// 解析后的工具调用
    struct ParsedToolCall {
        let id: String
        let name: String
        let input: [String: AnyJSON]
        var inputAsJSON: String {
            let data = try! JSONEncoder().encode(AnyJSON.object(input))
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    struct ChatResult {
        let text: String?
        let toolCalls: [ParsedToolCall]
        let stopReason: String
    }

    enum DeepSeekError: Error, LocalizedError {
        case noAPIKey
        case invalidResponse
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: "未设置 DeepSeek API Key"
            case .invalidResponse: "API 返回格式异常"
            case .httpError(let c, let b): "HTTP \(c): \(b)"
            }
        }
    }

    // MARK: - 调用

    func chat(
        system: String?,
        messages: [Message],
        tools: [ToolDef]? = nil,
        toolChoice: ToolChoice = .auto
    ) async throws -> ChatResult {
        guard let key = apiKey else { throw DeepSeekError.noAPIKey }

        var urlComponents = URLComponents(string: "\(baseURL)/v1/messages")!
        // Anthropic Messages API 不支持 query parameter 的 beta 标记，直接发请求即可

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = Request(
            model: model,
            maxTokens: 2048,
            system: system,
            messages: messages,
            tools: tools,
            toolChoice: tools != nil ? toolChoice : nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw DeepSeekError.httpError(httpResponse.statusCode, bodyStr)
        }

        let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)

        let text = apiResponse.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n")

        let toolCalls = apiResponse.content
            .filter { $0.type == "tool_use" }
            .compactMap { block -> ParsedToolCall? in
                guard let id = block.id, let name = block.name else { return nil }
                return ParsedToolCall(id: id, name: name, input: block.input ?? [:])
            }

        return ChatResult(
            text: text?.isEmpty == false ? text : nil,
            toolCalls: toolCalls,
            stopReason: apiResponse.stopReason ?? "end_turn"
        )
    }
}