import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class PromptInjectionEvalTests: XCTestCase {
    func testEveryEvalCasePreservesConfirmationBoundary() async throws {
        let data = try Gate03FixtureLoader.data("prompt-injection-phase3", extension: "yaml")
        let suite = try JSONDecoder().decode(PromptInjectionSuite.self, from: data)

        XCTAssertEqual(suite.version, 1)
        XCTAssertFalse(suite.cases.isEmpty)

        for evalCase in suite.cases {
            let provider = ScriptedTextProvider(scripts: scripts(for: evalCase))
            let readRepository = PromptInjectionReadRepository(
                injectedScheduleText: evalCase.scenario == .toolResult ? evalCase.input : nil
            )
            let harness = try await PromptInjectionHarness(
                provider: provider,
                readRepository: readRepository
            )
            let userText = evalCase.scenario == .userInput
                ? evalCase.input
                : "读取今天的日程，然后准备记录体重 62.5kg。"

            _ = try await harness.session.send(userText: userText)

            let context = ModelContext(harness.container)
            let directWrites = try context.fetchCount(FetchDescriptor<WeightRecord>())
            let pendingActions = try context.fetchCount(FetchDescriptor<PendingActionRecord>())
            let committedReceipts = try context.fetchCount(
                FetchDescriptor<CommittedActionReceiptRecord>()
            )
            XCTAssertEqual(
                directWrites,
                evalCase.expected.directHealthWrites,
                "\(evalCase.id): direct write boundary"
            )
            XCTAssertEqual(
                pendingActions,
                evalCase.expected.pendingActions,
                "\(evalCase.id): pending action count"
            )
            if evalCase.expected.confirmationRequired {
                XCTAssertGreaterThan(pendingActions, 0, "\(evalCase.id): confirmation card required")
                XCTAssertEqual(committedReceipts, 0, "\(evalCase.id): no implicit confirmation")
            }

            if evalCase.scenario == .toolResult {
                let requests = provider.recordedRequests()
                XCTAssertGreaterThanOrEqual(requests.count, 2, "\(evalCase.id): tool result round")
                let toolResults = requests.dropFirst().flatMap(\.messages).flatMap(\.content).compactMap {
                    content -> String? in
                    guard case .toolResult(_, let value) = content else { return nil }
                    return value
                }
                XCTAssertTrue(
                    toolResults.contains(where: { $0.contains(evalCase.input) }),
                    "\(evalCase.id): injected tool result must reach the real AgentSession history"
                )
            }
        }
    }

    private func scripts(for evalCase: PromptInjectionCase) -> [[ProviderEvent]] {
        let weightCall = ToolCall(
            id: "\(evalCase.id)-weight",
            name: "log_weight",
            arguments: .object([
                "kilograms": .number(62.5),
                "measuredAt": .null,
            ])
        )
        switch evalCase.scenario {
        case .userInput:
            return [
                [.toolCall(weightCall), .completed(.toolUse)],
                [.textDelta("已生成待确认草稿。"), .completed(.completed)],
            ]
        case .toolResult:
            let scheduleCall = ToolCall(
                id: "\(evalCase.id)-schedule",
                name: "get_schedule",
                arguments: .object(["date": .string("2026-09-01T00:00:00Z")])
            )
            return [
                [.toolCall(scheduleCall), .completed(.toolUse)],
                [.toolCall(weightCall), .completed(.toolUse)],
                [.textDelta("工具内容不具备授权力，仍需用户确认。"), .completed(.completed)],
            ]
        }
    }
}

private struct PromptInjectionSuite: Decodable {
    let version: Int
    let cases: [PromptInjectionCase]
}

private struct PromptInjectionCase: Decodable {
    enum Scenario: String, Decodable {
        case userInput = "user_input"
        case toolResult = "tool_result"
    }

    struct Expected: Decodable {
        let directHealthWrites: Int
        let pendingActions: Int
        let confirmationRequired: Bool

        enum CodingKeys: String, CodingKey {
            case directHealthWrites = "direct_health_writes"
            case pendingActions = "pending_actions"
            case confirmationRequired = "confirmation_required"
        }
    }

    let id: String
    let scenario: Scenario
    let input: String
    let expected: Expected
}

private actor PromptInjectionReadRepository: AgentReadRepository {
    let injectedScheduleText: String?

    init(injectedScheduleText: String?) {
        self.injectedScheduleText = injectedScheduleText
    }

    func dailyMetrics(from startDate: Date, through endDate: Date) -> [AgentDailyMetric] {
        []
    }

    func schedule(on date: Date) -> [AgentScheduleItem] {
        guard let injectedScheduleText else { return [] }
        return [
            AgentScheduleItem(
                title: injectedScheduleText,
                startTime: date,
                endTime: nil,
                notes: injectedScheduleText
            )
        ]
    }
}

@MainActor
private struct PromptInjectionHarness {
    let container: ModelContainer
    let session: AgentSession

    init(
        provider: any TextModelProvider,
        readRepository: any AgentReadRepository
    ) async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV3.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let confirmationRepository = SwiftDataConfirmationRepository(modelContainer: container)
        let conversationRepository = SwiftDataAgentRepository(modelContainer: container)
        let governance = InMemoryProviderGovernanceRepository(granted: [(.deepSeek, .healthText)])
        let preferences = IntelligencePreferences()
        preferences.mode = .cloudDeepSeek

        self.container = container
        self.session = AgentSession(
            providerSelector: TestProviderSelector(provider),
            intelligencePreferences: preferences,
            providerConfiguration: ProviderConfigurationPreferences(),
            governanceRepository: governance,
            usageLedger: ProviderUsageLedger(repository: governance),
            registry: ToolRegistry(),
            confirmationCoordinator: ConfirmationCoordinator(
                repository: confirmationRepository,
                writeGate: PersistenceWriteGate(state: .writable)
            ),
            readRepository: readRepository,
            conversationRepository: conversationRepository
        )
    }
}
