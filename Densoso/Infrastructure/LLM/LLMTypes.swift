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
    case reasoning
    case streaming
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
    case none
    case low
    case high
    case max

    static var disabled: ThinkingPolicy { .none }
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
    case image(ImageInput)
    case toolCall(ToolCall)
    case toolResult(toolCallID: String, content: String)
    /// Opaque provider reasoning returned for a same-process tool continuation.
    /// AgentSession removes this item before persisting conversation history.
    case reasoning(JSONValue)
}

enum ImageDetail: String, Codable, Sendable {
    case low
    case high
    case original
    case auto
}

struct ImageInput: Codable, Equatable, Sendable {
    let mimeType: String
    let base64Data: String
    let detail: ImageDetail

    init(mimeType: String, base64Data: String, detail: ImageDetail = .high) {
        self.mimeType = mimeType
        self.base64Data = base64Data
        self.detail = detail
    }
}

/// One user-initiated multimodal turn. The sanitized image and extracted local
/// evidence are held only in memory; AgentSession persists the text turn and
/// later attaches bounded evidence to a pending meal action.
struct MultimodalModelRequest: Sendable {
    static let maximumJPEGBytes = 5_000_000
    static let maximumMealEvidenceCount = 12

    let userText: String
    let image: ImageInput?
    let mealEvidence: [MealEvidence]

    init(userText: String) {
        self.userText = userText
        self.image = nil
        self.mealEvidence = []
    }

    /// Evidence-only requests keep local scanner output in memory for this
    /// Agent turn; the evidence is not added to persisted conversation history.
    init(userText: String, mealEvidence: [MealEvidence]) {
        self.userText = userText
        self.image = nil
        self.mealEvidence = Self.boundedMealEvidence(mealEvidence)
    }

    init(userText: String, imageJPEG: Data, mealEvidence: [MealEvidence]) throws {
        guard !imageJPEG.isEmpty, imageJPEG.starts(with: [0xFF, 0xD8]) else {
            throw ProviderError.schemaViolation(path: "image")
        }
        guard imageJPEG.count <= Self.maximumJPEGBytes else {
            throw ProviderError.requestTooLarge(limitBytes: Self.maximumJPEGBytes)
        }
        self.userText = userText
        self.image = ImageInput(
            mimeType: "image/jpeg",
            base64Data: imageJPEG.base64EncodedString(),
            detail: .high
        )
        self.mealEvidence = Self.boundedMealEvidence(mealEvidence)
    }

    func includingSupplementalText(_ supplementalText: String) -> MultimodalModelRequest {
        let supplemental = supplementalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !supplemental.isEmpty else { return self }
        return MultimodalModelRequest(
            userText: "\(userText)\n\n用户补充说明：\(supplemental)",
            image: image,
            mealEvidence: mealEvidence
        )
    }

    private init(userText: String, image: ImageInput?, mealEvidence: [MealEvidence]) {
        self.userText = userText
        self.image = image
        self.mealEvidence = Self.boundedMealEvidence(mealEvidence)
    }

    private static func boundedMealEvidence(_ evidence: [MealEvidence]) -> [MealEvidence] {
        evidence.prefix(Self.maximumMealEvidenceCount).map { item in
            MealEvidence(
                id: item.id,
                kind: item.kind,
                value: String(item.value.prefix(160)),
                confidence: item.confidence.isFinite ? min(max(item.confidence, 0), 1) : 0,
                capturedAt: item.capturedAt,
                sourceVersion: item.sourceVersion.map { String($0.prefix(80)) }
            )
        }
    }
}

struct StructuredOutputFormat: Equatable, Sendable {
    let name: String
    let schema: JSONSchemaNode
    let strict: Bool

    init(name: String, schema: JSONSchemaNode, strict: Bool = true) {
        self.name = name
        self.schema = schema
        self.strict = strict
    }
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
    var responseFormat: StructuredOutputFormat? = nil
    let deadline: Date
}

struct ProviderUsage: Codable, Equatable, Sendable {
    let provider: ProviderID
    let model: String
    let capability: ProviderCapability
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let audioSeconds: Double
    let attempt: Int

    init(
        provider: ProviderID,
        model: String,
        capability: ProviderCapability,
        inputTokens: Int,
        outputTokens: Int,
        audioSeconds: Double,
        attempt: Int,
        cachedInputTokens: Int = 0,
        reasoningTokens: Int = 0
    ) {
        self.provider = provider
        self.model = model
        self.capability = capability
        self.inputTokens = max(inputTokens, 0)
        self.cachedInputTokens = max(cachedInputTokens, 0)
        self.outputTokens = max(outputTokens, 0)
        self.reasoningTokens = max(reasoningTokens, 0)
        self.audioSeconds = max(audioSeconds, 0)
        self.attempt = max(attempt, 0)
    }
}

enum ProviderStopReason: String, Codable, Sendable {
    case completed
    case toolUse
    case maxTokens
}

enum ProviderEvent: Equatable, Sendable {
    case textDelta(String)
    case toolCall(ToolCall)
    case reasoning(JSONValue)
    case usage(ProviderUsage)
    case completed(ProviderStopReason)
}

protocol MultimodalModelProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ProviderEvent, Error>
}

typealias TextModelProvider = MultimodalModelProvider
