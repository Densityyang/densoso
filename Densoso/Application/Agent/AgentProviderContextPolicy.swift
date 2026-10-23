import Foundation

/// Bounds only the provider-facing history. The complete local conversation
/// remains available for the chat transcript and audit history.
enum AgentProviderContextPolicy {
    static let maximumRecentTurns = 8
    static let maximumMessages = 64
    static let maximumEstimatedInputBytes = 96 * 1_024
    private static let imageBudgetBytes = 8 * 1_024

    static func boundedMessages(
        _ messages: [ModelMessage],
        currentTurnStartIndex: Int,
        additionalContextBytes: Int = 0
    ) throws -> [ModelMessage] {
        guard messages.indices.contains(currentTurnStartIndex) else {
            throw AgentError.contextWindowExceeded
        }
        let currentTurn = Array(messages[currentTurnStartIndex...])
        guard fits(currentTurn, additionalContextBytes: additionalContextBytes) else {
            throw AgentError.contextWindowExceeded
        }

        var selected = currentTurn
        let priorTurnStarts = messages[..<currentTurnStartIndex].enumerated().compactMap { item in
            item.element.role == .user ? item.offset : nil
        }
        for start in priorTurnStarts.suffix(maximumRecentTurns).reversed() {
            let candidate = Array(messages[start...])
            guard fits(candidate, additionalContextBytes: additionalContextBytes) else { break }
            selected = candidate
        }
        return selected
    }

    static func fixedContextBytes(systemPrompt: String, tools: [ToolSchema]) -> Int {
        let toolsBytes = (try? JSONEncoder().encode(tools).count) ?? maximumEstimatedInputBytes
        return systemPrompt.utf8.count + toolsBytes + 1_024
    }

    private static func fits(_ messages: [ModelMessage], additionalContextBytes: Int) -> Bool {
        messages.count <= maximumMessages
            && estimatedInputBytes(messages) + max(additionalContextBytes, 0) <= maximumEstimatedInputBytes
    }

    private static func estimatedInputBytes(_ messages: [ModelMessage]) -> Int {
        messages.reduce(0) { total, message in
            total + 48 + message.content.reduce(0) { contentTotal, content in
                contentTotal + estimatedInputBytes(content)
            }
        }
    }

    private static func estimatedInputBytes(_ content: ModelContent) -> Int {
        switch content {
        case .text(let value):
            return value.utf8.count
        case .toolResult(_, let value):
            return value.utf8.count + 64
        case .toolCall(let value):
            return encodedByteCount(of: value)
        case .reasoning(let value):
            return encodedByteCount(of: value)
        case .image:
            return imageBudgetBytes
        }
    }

    private static func encodedByteCount<Value: Encodable>(of value: Value) -> Int {
        (try? JSONEncoder().encode(value).count) ?? maximumEstimatedInputBytes
    }
}
