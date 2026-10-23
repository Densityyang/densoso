import XCTest
@testable import Densoso

final class AgentProviderContextPolicyTests: XCTestCase {
    func testProviderHistoryKeepsRecentWholeTurnsAndTheCurrentTurn() throws {
        var messages: [ModelMessage] = []
        for index in 0..<20 {
            messages.append(ModelMessage(role: .user, text: "history-user-\(index)"))
            messages.append(ModelMessage(role: .assistant, text: "history-assistant-\(index)"))
        }
        let currentTurnStartIndex = messages.count
        messages.append(ModelMessage(role: .user, text: "current-user-turn"))
        messages.append(ModelMessage(role: .assistant, content: [
            .toolCall(ToolCall(id: "current-tool", name: "read", arguments: .object([:]))),
        ]))
        messages.append(ModelMessage(role: .tool, content: [
            .toolResult(toolCallID: "current-tool", content: "current-tool-result"),
        ]))

        let bounded = try AgentProviderContextPolicy.boundedMessages(
            messages,
            currentTurnStartIndex: currentTurnStartIndex
        )
        let visibleText = bounded.flatMap { message in
            message.content.compactMap { content -> String? in
                if case .text(let text) = content { return text }
                if case .toolResult(_, let text) = content { return text }
                return nil
            }
        }

        XCTAssertEqual(bounded.count, 19)
        XCTAssertFalse(visibleText.contains("history-user-11"))
        XCTAssertTrue(visibleText.contains("history-user-12"))
        XCTAssertTrue(visibleText.contains("current-user-turn"))
        XCTAssertTrue(visibleText.contains("current-tool-result"))
        XCTAssertEqual(bounded.filter { $0.role == .user }.count, 9)
    }

    func testCurrentTurnOverBudgetFailsBeforeProviderInvocation() throws {
        let oversizedTurn = ModelMessage(
            role: .user,
            text: String(repeating: "x", count: AgentProviderContextPolicy.maximumEstimatedInputBytes + 1)
        )

        XCTAssertThrowsError(try AgentProviderContextPolicy.boundedMessages(
            [oversizedTurn],
            currentTurnStartIndex: 0
        )) { error in
            XCTAssertEqual(error as? AgentError, .contextWindowExceeded)
        }
    }
}
