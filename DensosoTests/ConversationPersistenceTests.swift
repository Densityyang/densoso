import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class ConversationPersistenceTests: XCTestCase {
    func testMessageQueriesAndResetStayScopedToConversationAndRequest() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV7.self)
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
        let schema = Schema(versionedSchema: DensosoSchemaV7.self)
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

    func testMessagePagesPreserveOrdinalAndResumeFilterAcrossPageBoundary() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000421")!
        let otherConversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000422")!
        let currentRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000423")!
        let previousRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000424")!
        let messageCount = SwiftDataAgentRepository.messageFetchBatchSize

        for ordinal in 0..<messageCount {
            context.insert(MessageRecord(
                id: fixtureUUID(50_000 + ordinal),
                conversationID: conversationID,
                roleRaw: "assistant",
                contentData: Data("previous-\(ordinal)".utf8),
                ordinal: ordinal,
                requestID: previousRequestID
            ))
        }
        context.insert(MessageRecord(
            id: fixtureUUID(51_000),
            conversationID: conversationID,
            roleRaw: "assistant",
            contentData: Data("current-tool".utf8),
            ordinal: messageCount,
            requestID: currentRequestID
        ))
        context.insert(MessageRecord(
            id: fixtureUUID(51_001),
            conversationID: conversationID,
            roleRaw: "assistant",
            contentData: Data("previous-answer".utf8),
            ordinal: messageCount + 1,
            requestID: previousRequestID
        ))
        context.insert(MessageRecord(
            id: fixtureUUID(51_002),
            conversationID: conversationID,
            roleRaw: "user",
            contentData: Data("current-user".utf8),
            ordinal: messageCount + 2,
            requestID: currentRequestID
        ))
        context.insert(MessageRecord(
            id: fixtureUUID(51_003),
            conversationID: otherConversationID,
            roleRaw: "assistant",
            contentData: Data("other-conversation".utf8),
            ordinal: messageCount + 3,
            requestID: previousRequestID
        ))
        try context.save()

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let messages = try await repository.messageData(conversationID: conversationID)
        let resumeHistory = try await repository.resumeHistory(
            conversationID: conversationID,
            requestID: currentRequestID
        )

        XCTAssertEqual(messages.count, messageCount + 3)
        XCTAssertEqual(messages.map { String(decoding: $0, as: UTF8.self) },
                        (0..<messageCount).map { "previous-\($0)" } + ["current-tool", "previous-answer", "current-user"])
        XCTAssertEqual(resumeHistory.map { String(decoding: $0, as: UTF8.self) },
                        (0..<messageCount).map { "previous-\($0)" } + ["previous-answer", "current-user"])
    }

    func testResetPagesMessagesAndRequestsAcross64RowBoundaries() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV7.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000431")!
        let otherConversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000432")!
        let context = ModelContext(container)
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 0..<65 {
            let requestID = UUID()
            context.insert(MessageRecord(
                conversationID: conversationID,
                roleRaw: "user",
                contentData: Data("message-\(index)".utf8),
                ordinal: index,
                requestID: requestID
            ))
            context.insert(AgentRequestRecord(
                requestID: requestID,
                conversationID: conversationID,
                startedAt: startedAt.addingTimeInterval(TimeInterval(index)),
                absoluteDeadline: startedAt.addingTimeInterval(TimeInterval(index + 60)),
                maximumProviderRounds: 5,
                maximumToolCalls: 8
            ))
        }
        let otherRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000433")!
        context.insert(MessageRecord(
            conversationID: otherConversationID,
            roleRaw: "user",
            contentData: Data("preserved".utf8),
            ordinal: 0,
            requestID: otherRequestID
        ))
        context.insert(AgentRequestRecord(
            requestID: otherRequestID,
            conversationID: otherConversationID,
            startedAt: startedAt,
            absoluteDeadline: startedAt.addingTimeInterval(60),
            maximumProviderRounds: 5,
            maximumToolCalls: 8
        ))
        try context.save()

        try await SwiftDataAgentRepository(modelContainer: container).reset(conversationID: conversationID)

        let verificationContext = ModelContext(container)
        let messages = try verificationContext.fetch(FetchDescriptor<MessageRecord>())
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.conversationID, otherConversationID)
        XCTAssertEqual(messages.first?.contentData, Data("preserved".utf8))
        let requests = try verificationContext.fetch(FetchDescriptor<AgentRequestRecord>())
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.requestID, otherRequestID)
    }

    func testAgentRestorePublishesUserVisibleConversationMessages() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV7.self)
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

    private func fixtureUUID(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", suffix))!
    }
}
