import Foundation
import SwiftData

/// Agent 会话 —— Anthropic Messages API 格式 ReAct loop
@Observable
final class AgentSession {
    private let client: DeepSeekClient
    private let registry: ToolRegistry
    private let systemPrompt: AgentSystemPrompt

    weak var foodDatabase: FoodDatabase?
    private var conversationHistory: [DeepSeekClient.Message] = []

    init(client: DeepSeekClient, registry: ToolRegistry) {
        self.client = client
        self.registry = registry
        self.systemPrompt = AgentSystemPrompt()
    }

    /// 发送用户文本，返回 agent 最终文本回复
    func send(userText: String, modelContext: ModelContext) async throws -> AgentResponse {
        conversationHistory.append(DeepSeekClient.Message(role: "user", text: userText))

        for _ in 0..<5 {
            let result = try await client.chat(
                system: systemPrompt.text,
                messages: conversationHistory,
                tools: registry.toolDefinitions,
                toolChoice: .auto
            )

            if !result.toolCalls.isEmpty {
                // 构造 assistant 消息（包含 tool_use 块）
                var assistantBlocks: [DeepSeekClient.ContentBlock] = []
                if let text = result.text {
                    assistantBlocks.append(DeepSeekClient.ContentBlock(type: "text", text: text))
                }
                for tc in result.toolCalls {
                    assistantBlocks.append(DeepSeekClient.ContentBlock(
                        type: "tool_use",
                        id: tc.id,
                        name: tc.name,
                        input: tc.input
                    ))
                }
                conversationHistory.append(DeepSeekClient.Message(role: "assistant", blocks: assistantBlocks))

                // 执行工具
                var toolResultBlocks: [DeepSeekClient.ContentBlock] = []
                for tc in result.toolCalls {
                    let output = await executeTool(name: tc.name, input: tc.input, modelContext: modelContext)
                    toolResultBlocks.append(DeepSeekClient.ContentBlock(
                        type: "tool_result",
                        toolUseId: tc.id,
                        content: .string(output)
                    ))
                }
                conversationHistory.append(DeepSeekClient.Message(role: "user", blocks: toolResultBlocks))
                continue
            }

            if let text = result.text {
                conversationHistory.append(DeepSeekClient.Message(role: "assistant", text: text))
                return AgentResponse(text: text, toolCallsCount: 0)
            }

            throw AgentError.emptyResponse
        }

        throw AgentError.tooManyRounds
    }

    private func executeTool(name: String, input: [String: DeepSeekClient.AnyJSON], modelContext: ModelContext) async -> String {
        do {
            let inputData = try JSONEncoder().encode(DeepSeekClient.AnyJSON.object(input))
            let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"
            return try await registry.execute(name: name, argumentsJSON: inputJSON, context: self, modelContext: modelContext)
        } catch {
            return #"{"error": "\#(error.localizedDescription)"}"#
        }
    }

    func reset() {
        conversationHistory.removeAll()
    }
}

struct AgentResponse {
    let text: String
    let toolCallsCount: Int
}

enum AgentError: Error, LocalizedError {
    case emptyResponse
    case tooManyRounds
    var errorDescription: String? {
        switch self {
        case .emptyResponse: "Agent 未返回有效响应"
        case .tooManyRounds: "Agent 工具调用轮次过多"
        }
    }
}
