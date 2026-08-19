import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class ConversationPersistenceTests: XCTestCase {
    func testConversationMessagesSurviveRepositoryRecreationInOrdinalOrder() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV3.self)
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
            requestID: UUID()
        )
        try await firstRepository.appendMessage(
            conversationID: conversationID,
            role: "assistant",
            contentData: Data("second".utf8),
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
        let schema = Schema(versionedSchema: DensosoSchemaV3.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let agentRepository = SwiftDataAgentRepository(modelContainer: container)
        for message in [
            DeepSeekClient.Message(role: "user", text: "记录午餐"),
            DeepSeekClient.Message(role: "assistant", text: "请确认草稿"),
        ] {
            try await agentRepository.appendMessage(
                conversationID: conversationID,
                role: message.role,
                contentData: JSONEncoder().encode(message),
                requestID: UUID()
            )
        }
        let confirmationRepository = SwiftDataConfirmationRepository(modelContainer: container)
        let session = AgentSession(
            client: DeepSeekClient(),
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
