import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class ConversationPersistenceTests: XCTestCase {
    func testMessageQueriesAndResetStayScopedToConversationAndRequest() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000411")!
        let otherConversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000412")!
        let currentRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000413")!
        let previousRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000414")!
        let otherRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000415")!
        let repository = SwiftDataAgentRepository(modelContainer: container)

        try await repository.appendMessage(
            conversationID: conversationID,
            role: "user",
            contentData: Data("current-user".utf8),
            toolSummaryData: nil,
            requestID: currentRequestID
        )
        try await repository.appendMessage(
            conversationID: conversationID,
            role: "assistant",
            contentData: Data("current-tool".utf8),
            toolSummaryData: Data("tool-summary".utf8),
            requestID: currentRequestID
        )
        try await repository.appendMessage(
            conversationID: conversationID,
            role: "assistant",
            contentData: Data("previous-answer".utf8),
            toolSummaryData: nil,
            requestID: previousRequestID
        )
        try await repository.appendMessage(
            conversationID: conversationID,
            role: "assistant",
            contentData: Data("current-answer".utf8),
            toolSummaryData: nil,
            requestID: currentRequestID
        )
        try await repository.appendMessage(
            conversationID: conversationID,
            role: "assistant",
            contentData: Data("legacy-answer".utf8),
            toolSummaryData: nil,
            requestID: nil
        )
        try await repository.appendMessage(
            conversationID: otherConversationID,
            role: "user",
            contentData: Data("other-conversation".utf8),
            toolSummaryData: nil,
            requestID: otherRequestID
        )

        let messages = try await repository.messageData(conversationID: conversationID)
        XCTAssertEqual(messages.map { String(decoding: $0, as: UTF8.self) }, [
            "current-user", "current-tool", "previous-answer", "current-answer", "legacy-answer",
        ])
        let resumeHistory = try await repository.resumeHistory(
            conversationID: conversationID,
            requestID: currentRequestID
        )
        XCTAssertEqual(resumeHistory.map { String(decoding: $0, as: UTF8.self) }, [
            "current-user", "previous-answer", "legacy-answer",
        ])
        let containsCurrentRequest = try await repository.containsRequestID(
            currentRequestID,
            conversationID: conversationID
        )
        let containsOtherConversationRequest = try await repository.containsRequestID(
            currentRequestID,
            conversationID: otherConversationID
        )
        XCTAssertTrue(containsCurrentRequest)
        XCTAssertFalse(containsOtherConversationRequest)
        let containsCompletedResponse = try await repository.containsCompletedResponse(
            requestID: currentRequestID,
            conversationID: conversationID
        )
        let otherConversationHasCompletedResponse = try await repository.containsCompletedResponse(
            requestID: currentRequestID,
            conversationID: otherConversationID
        )
        XCTAssertTrue(containsCompletedResponse)
        XCTAssertFalse(otherConversationHasCompletedResponse)

        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for (requestID, ownerID) in [(currentRequestID, conversationID), (otherRequestID, otherConversationID)] {
            context.insert(AgentRequestRecord(
                requestID: requestID,
                conversationID: ownerID,
                startedAt: now,
                absoluteDeadline: now.addingTimeInterval(60),
                maximumProviderRounds: 3,
                maximumToolCalls: 4
            ))
        }
        try context.save()

        try await repository.reset(conversationID: conversationID)

        let verificationContext = ModelContext(container)
        let remainingMessages = try verificationContext.fetch(FetchDescriptor<MessageRecord>())
        XCTAssertEqual(remainingMessages.count, 1)
        XCTAssertEqual(remainingMessages.first?.conversationID, otherConversationID)
        let remainingRequests = try verificationContext.fetch(FetchDescriptor<AgentRequestRecord>())
        XCTAssertEqual(remainingRequests.count, 1)
        XCTAssertEqual(remainingRequests.first?.conversationID, otherConversationID)
    }

    func testConversationMessagesSurviveRepositoryRecreationInOrdinalOrder() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let firstRepository = SwiftDataAgentRepository(modelContainer: container)
        try await firstRepository.appendMessage(
            conversationID: conversationID,
            role: "user",
            contentData: Data("first".utf8),
            toolSummaryData: nil,
            requestID: UUID()
        )
        try await firstRepository.appendMessage(
            conversationID: conversationID,
            role: "assistant",
            contentData: Data("second".utf8),
            toolSummaryData: nil,
            requestID: nil
        )

        let recreatedRepository = SwiftDataAgentRepository(modelContainer: container)
        let messages = try await recreatedRepository.messageData(conversationID: conversationID)

        XCTAssertEqual(messages.map { String(decoding: $0, as: UTF8.self) }, ["first", "second"])
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ConversationRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MessageRecord>()), 2)
    }

    func testAgentRestorePublishesUserVisibleConversationMessages() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let agentRepository = SwiftDataAgentRepository(modelContainer: container)
        for message in [
            ModelMessage(role: .user, text: "记录午餐"),
            ModelMessage(role: .assistant, text: "请确认草稿"),
        ] {
            try await agentRepository.appendMessage(
                conversationID: conversationID,
                role: message.role.rawValue,
                contentData: JSONEncoder().encode(message),
                toolSummaryData: nil,
                requestID: UUID()
            )
        }
        let confirmationRepository = SwiftDataConfirmationRepository(modelContainer: container)
        let governance = InMemoryProviderGovernanceRepository(granted: [(.deepSeek, .healthText)])
        let preferences = IntelligencePreferences()
        preferences.mode = .cloudDeepSeek
        let session = AgentSession(
            providerSelector: TestProviderSelector(ScriptedTextProvider(scripts: [])),
            intelligencePreferences: preferences,
            providerConfiguration: ProviderConfigurationPreferences(),
            governanceRepository: governance,
            usageLedger: ProviderUsageLedger(repository: governance),
            registry: ToolRegistry(),
            confirmationCoordinator: ConfirmationCoordinator(
                repository: confirmationRepository,
                writeGate: PersistenceWriteGate(state: .writable)
            ),
            readRepository: agentRepository,
            conversationRepository: agentRepository
        )

        try await session.restore()

        XCTAssertEqual(session.restoredVisibleMessages.map(\.text), ["记录午餐", "请确认草稿"])
        XCTAssertEqual(session.restoredVisibleMessages.map(\.isUser), [true, false])
    }
}
