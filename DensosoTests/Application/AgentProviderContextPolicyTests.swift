import Foundation
import XCTest
@testable import Densoso

@MainActor
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

    func testDeniedHealthClassSentinelsAreAbsentFromSerializedProviderContinuationBodies() async throws {
        let scenarios: [(denied: ProviderDataClass, sentinels: [String], allowedSentinel: String, removesRecovery: Bool, removesTrainingLoad: Bool)] = [
            (
                .healthNutrition,
                ["nutrition-status-sentinel", "nutrition.value.SENTINEL", "nutrition.derived.SENTINEL", "10101", "10102"],
                "sleep.value.SENTINEL",
                false,
                false
            ),
            (
                .healthSleep,
                ["sleep-status-sentinel", "sleep.value.SENTINEL", "sleep.derived.SENTINEL", "20201", "20202"],
                "activity.value.SENTINEL",
                true,
                false
            ),
            (
                .healthActivity,
                ["activity-status-sentinel", "activity.value.SENTINEL", "activity.derived.SENTINEL", "trainingLoad.derived.SENTINEL", "30301", "30302", "30303"],
                "body.value.SENTINEL",
                true,
                true
            ),
            (
                .healthBody,
                ["body-status-sentinel", "body.value.SENTINEL", "body.derived.SENTINEL", "40401", "40402"],
                "nutrition.value.SENTINEL",
                true,
                false
            ),
            (
                .healthSubjective,
                ["subjective-status-sentinel", "subjective.value.SENTINEL", "subjective.derived.SENTINEL", "50501", "50502"],
                "activity.value.SENTINEL",
                false,
                false
            ),
        ]
        let payloadObject: [String: Any] = [
            "status": "available",
            "message": "unfiltered-root-message-sentinel",
            "startDate": "2026-10-01",
            "endDate": "2026-10-01",
            "days": [[
                "date": "2026-10-01",
                "domainStatuses": [
                    "nutrition": "nutrition-status-sentinel",
                    "sleep": "sleep-status-sentinel",
                    "activity": "activity-status-sentinel",
                    "body": "body-status-sentinel",
                    "subjective": "subjective-status-sentinel",
                ],
                "observations": [
                    "nutrition.value.SENTINEL": 10101,
                    "nutrition.derived.SENTINEL": 10102,
                    "sleep.value.SENTINEL": 20201,
                    "sleep.derived.SENTINEL": 20202,
                    "activity.value.SENTINEL": 30301,
                    "activity.derived.SENTINEL": 30302,
                    "trainingLoad.derived.SENTINEL": 30303,
                    "body.value.SENTINEL": 40401,
                    "body.derived.SENTINEL": 40402,
                    "subjective.value.SENTINEL": 50501,
                    "subjective.derived.SENTINEL": 50502,
                ],
                "recoveryStatus": "recovery.derived.SENTINEL",
                "trainingLoadBand": "trainingLoad.derived.SENTINEL",
            ]],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
        let payload = String(decoding: payloadData, as: UTF8.self)

        for providerID in [ProviderID.deepSeek, .qwen] {
            for scenario in scenarios {
                let allowedClasses = Set(CloudHealthContextPolicy.dataClasses).subtracting([scenario.denied])
                let policy = CloudHealthContextPolicy(provider: providerID, allowedClasses: allowedClasses)
                let callID = "history-\(providerID.rawValue)-\(scenario.denied.rawValue)"
                let continuationMessages = [
                    ModelMessage(role: .user, text: "继续查询"),
                    ModelMessage(role: .assistant, content: [
                        .toolCall(ToolCall(id: callID, name: "get_health_history", arguments: .object([:]))),
                    ]),
                    ModelMessage(role: .tool, content: [
                        .toolResult(toolCallID: callID, content: payload),
                    ]),
                ]
                let guardedMessages = CloudRequestPolicyGuard.filterToolResults(
                    continuationMessages,
                    by: policy
                )
                let request = ModelRequest(
                    requestID: UUID(),
                    conversationID: UUID(),
                    systemPrompt: "fixture",
                    messages: guardedMessages,
                    tools: [],
                    maxOutputTokens: 64,
                    thinking: .none,
                    deadline: Date().addingTimeInterval(30)
                )
                let transport: ScriptedProviderHTTPTransport
                if providerID == .deepSeek {
                    transport = ScriptedProviderHTTPTransport(steps: [
                        .response(
                            status: 200,
                            data: try Gate03FixtureLoader.data("deepseek-responses-stream", extension: "sse")
                        ),
                    ])
                    let provider = DeepSeekProvider(
                        credentialSource: TestCredentialSource(values: [.deepSeek: "fixture-key"]),
                        transport: transport,
                        jitter: { _ in 0 }
                    )
                    _ = try await collect(provider.stream(request))
                } else {
                    transport = ScriptedProviderHTTPTransport(steps: [
                        .response(status: 200, data: try Gate03FixtureLoader.data("qwen-text-tool-response")),
                    ])
                    let provider = QwenProvider(
                        endpoint: URL(string: "https://fixture.invalid/chat/completions")!,
                        credentialSource: TestCredentialSource(values: [.qwen: "fixture-key"]),
                        transport: transport,
                        jitter: { _ in 0 }
                    )
                    _ = try await collect(provider.stream(request))
                }

                let capturedRequests = await transport.recordedRequests()
                let captured = try XCTUnwrap(capturedRequests.first)
                let body = String(decoding: try XCTUnwrap(captured.httpBody), as: UTF8.self)
                for sentinel in scenario.sentinels {
                    XCTAssertFalse(
                        body.localizedCaseInsensitiveContains(sentinel),
                        "Denied \(scenario.denied.rawValue) sentinel reached \(providerID.rawValue) HTTP body: \(sentinel)"
                    )
                }
                XCTAssertTrue(
                    body.localizedCaseInsensitiveContains(scenario.allowedSentinel),
                    "An allowed category should remain in the \(providerID.rawValue) HTTP body when denying \(scenario.denied.rawValue)"
                )
                XCTAssertFalse(body.contains("unfiltered-root-message-sentinel"))
                if scenario.removesRecovery {
                    XCTAssertFalse(body.contains("recovery.derived.SENTINEL"))
                }
                if scenario.removesTrainingLoad {
                    XCTAssertFalse(body.contains("trainingLoad.derived.SENTINEL"))
                }
            }
        }
    }
}
