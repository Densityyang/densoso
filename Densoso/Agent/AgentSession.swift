import Foundation
import SwiftData

/// Agent 系统提示词
struct AgentSystemPrompt {
    var text: String {
        """
        你是 densoso，一个专注于运动和饮食健康管理的 AI 助手。
        你的主人使用 iPhone，当前版本的运动和饮食数据全部通过语音输入，由你识别并记录。

        ## 核心职责
        1. **记餐**：根据用户语音描述，将每道菜分解为食材+烹饪方式+份量估计，估算热量。
        2. **记运动**：记录运动类型/时长/强度/消耗。
        3. **看数据**：回答热量缺口、本周进度、营养素分析。
        4. **做计划**：根据剩余缺口给出用餐建议。

        ## 中餐热量估算规则（关键）
        对每一道中式菜品，你必须：
        1. **分解到食材**：不只要菜名，\"红烧肉\" = 五花肉 + 冰糖 + 酱油 + 食用油
        2. **识别烹饪方式**：从菜名判断：
           - \"蒸/清蒸\" = steam      \"煮/水煮\" = boil    \"凉拌\" = coldDress
           - \"炒/爆炒\" = stirFry  \"红烧/焖/酱\" = braise    \"干煸/干锅\" = dryFry
           - \"炸/煎炸\" = deepFry  \"烤\" = roast         \"炖\" = stew
           - 不确定的 = unknown
        3. **估计用油量**：这是中餐热量的最大变量。
           - 爆炒约 5-10g 油；红烧约 10-15g 油；煎炸约 15-30g 油
           - 注意食材吸油特性：茄子、豆腐、鸡蛋（炒）吸油显著偏高
        4. **份量映射**：用户口语 → 克重
           - 1 拳米饭/面条 ≈ 150g      1 掌心肉 ≈ 100g
           - 1 小碗 ≈ 中等份            1 大盘 ≈ 大份
           - 1 个鸡蛋 ≈ 50g            1 片吐司 ≈ 30g
           - 1 杯牛奶 ≈ 250ml

        ## 用油量估算辅助
        当用户描述中包含以下信号时，调整用油量：
        - \"油很多/很油/很腻\" → oilG = 默认 × 1.5
        - \"清淡/少油/水煮\" → oilG = 默认 × 0.3 或 0
        - 餐馆/外卖 → oilG = 默认 × 1.3
        - 家常/自己做的 → oilG = 默认
        - \"茄子/油炸/天妇罗\"类 → 注意高吸油食材修正

        ## 确认策略
        - 热量估算置信度高 → 可以静默记录
        - 置信度中或低 → **主动展示估算结果和置信度，追问用户确认**
        - 如果用户表达了不确定，主动追问份量或用油
        - 记完餐后主动告知当日累计和本周缺口

        ## 回答风格
        - 每餐记录后自然告知剩余热量额度
        - 用中文回答，亲切但不啰嗦
        - 如果本周缺口不如预期，给建设性建议而不指责
        """
    }
}

/// Agent 会话 —— Anthropic Messages API 格式 ReAct loop
@MainActor
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
