import Foundation
import DensosoDomain

enum ProviderID: String, Codable, CaseIterable, Sendable {
    case deepSeek
    case qwen
}

enum ProviderCapability: String, Codable, CaseIterable, Sendable {
    case text
    case toolCalling
    case structuredOutput
    case vision
    case speech
}

struct ProviderDescriptor: Codable, Equatable, Sendable {
    let id: ProviderID
    let model: String
    let capabilities: Set<ProviderCapability>
}

enum ProviderDataClass: String, Codable, CaseIterable, Sendable {
    case healthText
    case mealImage
    case speechAudio
}

enum ThinkingPolicy: String, Codable, Sendable {
    case disabled
}

enum ModelRole: String, Codable, Sendable {
    case user
    case assistant
    case tool
}

struct ModelMessage: Codable, Equatable, Sendable {
    let role: ModelRole
    let content: [ModelContent]

    init(role: ModelRole, text: String) {
        self.role = role
        self.content = [.text(text)]
    }

    init(role: ModelRole, content: [ModelContent]) {
        self.role = role
        self.content = content
    }
}

enum ModelContent: Codable, Equatable, Sendable {
    case text(String)
    case toolCall(ToolCall)
    case toolResult(toolCallID: String, content: String)
}

struct ToolCall: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let arguments: JSONValue
}

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .integer(let value): value
        case .number(let value)
            where value.isFinite
                && value.rounded() == value
                && value > Double(Int.min)
                && value < Double(Int.max):
            Int(value)
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }

    var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

indirect enum JSONSchemaNode: Equatable, Sendable, Encodable {
    case object(
        properties: [String: JSONSchemaNode],
        required: [String],
        additionalProperties: Bool,
        description: String? = nil
    )
    case array(
        items: JSONSchemaNode,
        minimumItems: Int? = nil,
        maximumItems: Int? = nil,
        description: String? = nil
    )
    case string(
        allowedValues: [String]? = nil,
        format: String? = nil,
        minimumLength: Int? = nil,
        maximumLength: Int? = nil,
        description: String? = nil
    )
    case number(minimum: Double? = nil, maximum: Double? = nil, description: String? = nil)
    case integer(minimum: Int? = nil, maximum: Int? = nil, description: String? = nil)
    case boolean(description: String? = nil)
    case null
    case anyOf([JSONSchemaNode], description: String? = nil)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .object(let properties, let required, let additionalProperties, let description):
            try container.encode("object", forKey: .type)
            try container.encode(properties, forKey: .properties)
            try container.encode(required, forKey: .required)
            try container.encode(additionalProperties, forKey: .additionalProperties)
            try container.encodeIfPresent(description, forKey: .description)
        case .array(let items, let minimumItems, let maximumItems, let description):
            try container.encode("array", forKey: .type)
            try container.encode(items, forKey: .items)
            try container.encodeIfPresent(minimumItems, forKey: .minimumItems)
            try container.encodeIfPresent(maximumItems, forKey: .maximumItems)
            try container.encodeIfPresent(description, forKey: .description)
        case .string(let allowedValues, let format, let minimumLength, let maximumLength, let description):
            try container.encode("string", forKey: .type)
            try container.encodeIfPresent(allowedValues, forKey: .allowedValues)
            try container.encodeIfPresent(format, forKey: .format)
            try container.encodeIfPresent(minimumLength, forKey: .minimumLength)
            try container.encodeIfPresent(maximumLength, forKey: .maximumLength)
            try container.encodeIfPresent(description, forKey: .description)
        case .number(let minimum, let maximum, let description):
            try container.encode("number", forKey: .type)
            try container.encodeIfPresent(minimum, forKey: .minimum)
            try container.encodeIfPresent(maximum, forKey: .maximum)
            try container.encodeIfPresent(description, forKey: .description)
        case .integer(let minimum, let maximum, let description):
            try container.encode("integer", forKey: .type)
            try container.encodeIfPresent(minimum, forKey: .minimum)
            try container.encodeIfPresent(maximum, forKey: .maximum)
            try container.encodeIfPresent(description, forKey: .description)
        case .boolean(let description):
            try container.encode("boolean", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
        case .null:
            try container.encode("null", forKey: .type)
        case .anyOf(let alternatives, let description):
            try container.encode(alternatives, forKey: .anyOf)
            try container.encodeIfPresent(description, forKey: .description)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case properties
        case required
        case additionalProperties
        case items
        case minimumItems = "minItems"
        case maximumItems = "maxItems"
        case allowedValues = "enum"
        case format
        case minimumLength = "minLength"
        case maximumLength = "maxLength"
        case minimum
        case maximum
        case description
        case anyOf
    }
}

struct ToolSchema: Equatable, Sendable, Encodable {
    let name: String
    let description: String
    let effect: ToolEffect
    let parameters: JSONSchemaNode
}

struct ModelRequest: Sendable {
    let requestID: UUID
    let conversationID: UUID
    let systemPrompt: String?
    let messages: [ModelMessage]
    let tools: [ToolSchema]
    let maxOutputTokens: Int
    let thinking: ThinkingPolicy
    let deadline: Date
}

struct ProviderUsage: Codable, Equatable, Sendable {
    let provider: ProviderID
    let model: String
    let capability: ProviderCapability
    let inputTokens: Int
    let outputTokens: Int
    let audioSeconds: Double
    let attempt: Int
}

enum ProviderStopReason: String, Codable, Sendable {
    case completed
    case toolUse
    case maxTokens
}

enum ProviderEvent: Equatable, Sendable {
    case textDelta(String)
    case toolCall(ToolCall)
    case usage(ProviderUsage)
    case completed(ProviderStopReason)
}

protocol TextModelProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ProviderEvent, Error>
}
