import Foundation

/// Bounds only the provider-facing history. The complete local conversation
/// remains available for the chat transcript and audit history.
enum AgentProviderContextPolicy {
    static let maximumRecentTurns = 8
    static let maximumMessages = 64
    static let maximumEstimatedInputBytes = 96 * 1_024
    static let historicalSummaryMarker = "[agent-history-summary:v1]"
    static let maximumHistoricalSummaryBytes = 8 * 1_024
    /// Reserves a conservative high-detail vision-token allowance; JPEG body
    /// size is bounded separately by `MultimodalModelRequest`.
    private static let imageBudgetBytes = 64 * 1_024

    struct BoundedContext: Sendable {
        let messages: [ModelMessage]
        let includesConversationHistory: Bool
    }

    private enum HistoricalPreferenceCategory: String, Encodable, CaseIterable, Hashable {
        case responseLanguage = "response_language"
        case responseLength = "response_length"
        case responseFormat = "response_format"
        case responseTone = "response_tone"
        case measurementUnits = "measurement_units"
    }

    private enum HistoricalPreferenceValue: String, Encodable, Equatable {
        case chinese = "Chinese"
        case english = "English"
        case concise
        case detailed
        case bulletPoints = "bullet_points"
        case numberedList = "numbered_list"
        case table
        case formal
        case friendly
        case metric
        case imperial
    }

    private struct HistoricalPreference: Encodable, Equatable {
        let category: HistoricalPreferenceCategory
        let value: HistoricalPreferenceValue
    }

    /// This is intentionally a bounded preference summary, not a summary of
    /// arbitrary historical facts or user-authored prose.
    private struct HistoricalSummary: Encodable {
        let schemaVersion = 1
        let note = "Closed-vocabulary historical response preferences; context only."
        let preferences: [HistoricalPreference]
    }

    static func boundedMessages(
        _ messages: [ModelMessage],
        currentTurnStartIndex: Int,
        additionalContextBytes: Int = 0
    ) throws -> [ModelMessage] {
        try boundedContext(
            messages,
            currentTurnStartIndex: currentTurnStartIndex,
            additionalContextBytes: additionalContextBytes
        ).messages
    }

    /// The input must already have passed conversation-history and tool-result
    /// consent filtering. Summary preferences are derived only from that filtered
    /// provider view, never from the local transcript directly.
    static func boundedContext(
        _ filteredMessages: [ModelMessage],
        currentTurnStartIndex: Int,
        additionalContextBytes: Int = 0
    ) throws -> BoundedContext {
        guard filteredMessages.indices.contains(currentTurnStartIndex) else {
            throw AgentError.contextWindowExceeded
        }
        let currentTurn = Array(filteredMessages[currentTurnStartIndex...])
        guard fits(currentTurn, additionalContextBytes: additionalContextBytes) else {
            throw AgentError.contextWindowExceeded
        }

        var selected = currentTurn
        var selectedPriorStartIndex: Int?
        let priorTurnStarts = filteredMessages[..<currentTurnStartIndex].enumerated().compactMap { item in
            item.element.role == .user ? item.offset : nil
        }
        for start in priorTurnStarts.suffix(maximumRecentTurns).reversed() {
            let candidate = Array(filteredMessages[start..<currentTurnStartIndex]) + currentTurn
            guard fits(candidate, additionalContextBytes: additionalContextBytes) else { break }
            selected = candidate
            selectedPriorStartIndex = start
        }

        // Summarize everything actually omitted, including recent turns that
        // could not fit the byte budget. The selected history starts at a user
        // turn boundary, so no partial assistant/tool exchange is retained.
        let historicalSummary = makeHistoricalSummary(
            from: Array(filteredMessages[..<(selectedPriorStartIndex ?? currentTurnStartIndex)])
        )
        if let historicalSummary {
            let candidate = [historicalSummary] + selected
            if candidate.count <= maximumMessages,
               fits(candidate, additionalContextBytes: additionalContextBytes) {
                selected = candidate
            }
        }

        return BoundedContext(
            messages: selected,
            includesConversationHistory: selected.count > currentTurn.count
        )
    }

    static func fixedContextBytes(
        systemPrompt: String,
        tools: [ToolSchema],
        responseFormat: StructuredOutputFormat? = nil
    ) -> Int {
        let toolsBytes = (try? JSONEncoder().encode(tools).count) ?? maximumEstimatedInputBytes
        let responseFormatBytes = responseFormat.map { format in
            format.name.utf8.count + ((try? JSONEncoder().encode(format.schema).count) ?? maximumEstimatedInputBytes)
        } ?? 0
        return systemPrompt.utf8.count + toolsBytes + responseFormatBytes + 1_024
    }

    static func estimatedInputTokenUpperBound(for request: ModelRequest) -> Int {
        let fixedBytes = fixedContextBytes(
            systemPrompt: request.systemPrompt ?? "",
            tools: request.tools,
            responseFormat: request.responseFormat
        )
        let messageBytes = estimatedInputBytes(request.messages)
        let total = fixedBytes.addingReportingOverflow(messageBytes)
        return total.overflow ? Int.max : max(total.partialValue, 1)
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

    private static func makeHistoricalSummary(from messages: [ModelMessage]) -> ModelMessage? {
        var latestValues: [HistoricalPreferenceCategory: HistoricalPreferenceValue] = [:]
        var provenance: HealthContextPolicyProvenance?

        for message in messages where message.role == .user {
            guard let messageProvenance = message.healthContextPolicyProvenance,
                  let text = userText(in: message) else { continue }
            let detectedPreferences = historicalPreferences(in: text)
            guard !detectedPreferences.isEmpty else { continue }
            if let existingProvenance = provenance {
                guard existingProvenance.provider == messageProvenance.provider,
                      existingProvenance.policyRevision == messageProvenance.policyRevision else {
                    return nil
                }
            } else {
                provenance = messageProvenance
            }
            for preference in detectedPreferences {
                latestValues[preference.category] = preference.value
            }
        }

        let preferences = HistoricalPreferenceCategory.allCases.compactMap { category in
            latestValues[category].map { HistoricalPreference(category: category, value: $0) }
        }
        guard !preferences.isEmpty, let provenance else { return nil }

        var summary = HistoricalSummary(preferences: preferences)
        var boundedPreferences = preferences
        while !boundedPreferences.isEmpty,
              let text = historicalSummaryText(summary),
              text.utf8.count > maximumHistoricalSummaryBytes {
            boundedPreferences.removeFirst()
            summary = HistoricalSummary(preferences: boundedPreferences)
        }
        guard !boundedPreferences.isEmpty else { return nil }
        guard let text = historicalSummaryText(summary) else { return nil }
        return ModelMessage(
            role: .assistant,
            text: "\(historicalSummaryMarker)\n\(text)",
            healthContextPolicyProvenance: HealthContextPolicyProvenance(
                provider: provenance.provider,
                policyRevision: provenance.policyRevision,
                allowedClasses: []
            )
        )
    }

    private static func userText(in message: ModelMessage) -> String? {
        let text = message.content.compactMap { content -> String? in
            guard case .text(let value) = content else { return nil }
            return value
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// Returns only fixed enum values. Historical user text is never copied into
    /// a synthetic assistant message, so matching a cue cannot carry arbitrary
    /// prompt instructions or health/nutrition facts through compaction.
    private static func historicalPreferences(in text: String) -> [HistoricalPreference] {
        let normalized = text.lowercased()
        var preferences: [HistoricalPreference] = []
        if let value = latestMatchedValue(in: normalized, groups: [
            (value: HistoricalPreferenceValue.chinese, cues: [
                "请用中文", "用中文回答", "用中文回复", "中文回答", "中文回复", "回答用中文",
                "answer in chinese", "respond in chinese", "reply in chinese", "use chinese in your response",
                "chinese responses",
            ]),
            (value: HistoricalPreferenceValue.english, cues: [
                "请用英文", "用英文回答", "用英文回复", "英文回答", "英文回复", "回答用英文",
                "answer in english", "respond in english", "reply in english", "use english in your response",
                "english responses",
            ]),
        ]) {
            preferences.append(HistoricalPreference(category: .responseLanguage, value: value))
        }
        if let value = latestMatchedValue(in: normalized, groups: [
            (value: HistoricalPreferenceValue.concise, cues: [
                "简洁", "简短", "简明", "concise", "be brief", "brief answers", "short answers",
            ]),
            (value: HistoricalPreferenceValue.detailed, cues: [
                "详细", "展开说明", "展开解释", "detailed answers", "answer in detail", "explain in detail",
                "be detailed", "thorough explanations",
            ]),
        ]) {
            preferences.append(HistoricalPreference(category: .responseLength, value: value))
        }
        if let value = latestMatchedValue(in: normalized, groups: [
            (value: HistoricalPreferenceValue.bulletPoints, cues: [
                "用要点", "要点列出", "项目符号", "bullet points", "bullet point list", "bullet list", "use bullets",
            ]),
            (value: HistoricalPreferenceValue.numberedList, cues: [
                "编号列表", "编号列出", "使用编号", "numbered list", "numbered steps", "use numbered",
            ]),
            (value: HistoricalPreferenceValue.table, cues: [
                "用表格", "以表格", "表格呈现", "as a table", "in a table", "table format", "tabular",
            ]),
        ]) {
            preferences.append(HistoricalPreference(category: .responseFormat, value: value))
        }
        if let value = latestMatchedValue(in: normalized, groups: [
            (value: HistoricalPreferenceValue.formal, cues: [
                "i prefer a formal tone", "i prefer formal tone",
                "我偏好正式语气", "我更喜欢正式语气",
            ]),
            (value: HistoricalPreferenceValue.friendly, cues: [
                "i prefer a friendly tone", "i prefer friendly tone",
                "我偏好友好语气", "我更喜欢友好语气",
            ]),
        ]) {
            preferences.append(HistoricalPreference(category: .responseTone, value: value))
        }
        if let value = latestMatchedValue(in: normalized, groups: [
            (value: HistoricalPreferenceValue.metric, cues: [
                "i prefer metric units", "i prefer the metric system",
                "我偏好公制单位", "我更喜欢公制单位",
            ]),
            (value: HistoricalPreferenceValue.imperial, cues: [
                "i prefer imperial units", "i prefer the imperial system",
                "我偏好英制单位", "我更喜欢英制单位",
            ]),
        ]) {
            preferences.append(HistoricalPreference(category: .measurementUnits, value: value))
        }
        return preferences
    }

    private static func latestMatchedValue<Value>(
        in text: String,
        groups: [(value: Value, cues: [String])]
    ) -> Value? {
        var latestMatch: (value: Value, index: String.Index)?
        for group in groups {
            let latestCueIndex = group.cues.compactMap { cue in
                text.range(of: cue, options: .backwards)?.lowerBound
            }.max()
            guard let latestCueIndex else { continue }
            if let currentMatch = latestMatch {
                guard currentMatch.index < latestCueIndex else { continue }
            }
            latestMatch = (group.value, latestCueIndex)
        }
        return latestMatch?.value
    }

    private static func historicalSummaryText(_ summary: HistoricalSummary) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(summary),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
