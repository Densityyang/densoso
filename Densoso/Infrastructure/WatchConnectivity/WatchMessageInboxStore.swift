import CryptoKit
import DensosoDomain
import Foundation
import SwiftData

enum WatchMessageIngestResult: Equatable {
    case accepted
    case duplicatePending
    case duplicateProcessed
    case payloadConflict
}

enum WatchReceiptState {
    static let pending = "pending"
    static let processed = "processed"
    static let rejected = "rejected"
}

@MainActor
final class WatchMessageInboxStore {
    static let conversationID = UUID(uuidString: "A7A81264-1866-4A0A-AF4A-78B920D5CB01")!

    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func ingest(_ envelope: WatchMessageEnvelope) throws -> WatchMessageIngestResult {
        let data = try WatchMessageCodec.encode(envelope)
        let key = envelope.messageID.uuidString.lowercased()
        let payloadHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let context = ModelContext(modelContainer)
        var result: WatchMessageIngestResult = .accepted

        try context.transaction {
            if let receipt = try context.fetch(FetchDescriptor<WatchMessageReceiptRecord>())
                .first(where: { $0.messageID == key }) {
                if receipt.payloadHash != payloadHash {
                    result = .payloadConflict
                } else if receipt.state == WatchReceiptState.processed || receipt.state == WatchReceiptState.rejected {
                    result = .duplicateProcessed
                } else {
                    result = .duplicatePending
                }
                return
            }

            let conversations = try context.fetch(FetchDescriptor<ConversationRecord>())
            if !conversations.contains(where: { $0.id == Self.conversationID }) {
                context.insert(ConversationRecord(
                    id: Self.conversationID,
                    state: "watchInbox",
                    title: "Watch Inbox"
                ))
            }
            let existingMessages = try context.fetch(FetchDescriptor<MessageRecord>())
                .filter { $0.conversationID == Self.conversationID }
            context.insert(MessageRecord(
                conversationID: Self.conversationID,
                roleRaw: "watch-envelope",
                contentData: data,
                ordinal: (existingMessages.map(\.ordinal).max() ?? -1) + 1,
                requestID: envelope.messageID
            ))
            context.insert(WatchMessageReceiptRecord(
                messageID: key,
                schemaVersion: envelope.schemaVersion,
                payloadHash: payloadHash
            ))
        }
        return result
    }

    func pendingTranscripts(excluding claimedIDs: Set<UUID> = []) throws -> [PendingWatchTranscript] {
        let context = ModelContext(modelContainer)
        let receipts = try context.fetch(FetchDescriptor<WatchMessageReceiptRecord>())
            .filter { $0.state == WatchReceiptState.pending }
        let pendingIDs = Set(receipts.compactMap { UUID(uuidString: $0.messageID) })
        let messages = try context.fetch(FetchDescriptor<MessageRecord>())
            .filter { $0.conversationID == Self.conversationID && $0.roleRaw == "watch-envelope" }
            .sorted { $0.ordinal < $1.ordinal }
        return messages.compactMap { message -> PendingWatchTranscript? in
                guard let id = message.requestID,
                      pendingIDs.contains(id),
                      !claimedIDs.contains(id),
                      let envelope = try? WatchMessageCodec.decode(message.contentData),
                      case .transcript(let text) = envelope.payload else { return nil }
                return PendingWatchTranscript(messageID: id, text: text)
            }
    }

    func pendingCommandEnvelopes() throws -> [WatchMessageEnvelope] {
        let context = ModelContext(modelContainer)
        let pendingReceipts = try context.fetch(FetchDescriptor<WatchMessageReceiptRecord>())
            .filter { $0.state == WatchReceiptState.pending }
        let pendingIDs = Set(pendingReceipts.compactMap { UUID(uuidString: $0.messageID) })
        let messages = try context.fetch(FetchDescriptor<MessageRecord>())
            .filter { $0.conversationID == Self.conversationID && $0.roleRaw == "watch-envelope" }
            .sorted { $0.ordinal < $1.ordinal }
        return messages.compactMap { message -> WatchMessageEnvelope? in
            guard let id = message.requestID,
                  pendingIDs.contains(id),
                  let envelope = try? WatchMessageCodec.decode(message.contentData) else { return nil }
            if case .transcript = envelope.payload { return nil }
            return envelope
        }
    }

    func setState(_ state: String, for messageID: UUID) throws {
        let context = ModelContext(modelContainer)
        let key = messageID.uuidString.lowercased()
        guard let receipt = try context.fetch(FetchDescriptor<WatchMessageReceiptRecord>())
            .first(where: { $0.messageID == key }) else { return }
        receipt.state = state
        receipt.processedAt = Date()
        try context.save()
    }

    func recentProcessedMessageIDs(limit: Int = 100) throws -> [UUID] {
        let context = ModelContext(modelContainer)
        return try context.fetch(FetchDescriptor<WatchMessageReceiptRecord>())
            .filter { $0.state == WatchReceiptState.processed || $0.state == WatchReceiptState.rejected }
            .sorted { ($0.processedAt ?? .distantPast) < ($1.processedAt ?? .distantPast) }
            .compactMap { UUID(uuidString: $0.messageID) }
            .suffix(max(limit, 0))
            .map { $0 }
    }

    func recentReceivedMessageIDs(limit: Int = 100) throws -> [UUID] {
        let inboxID = Self.conversationID
        return try ModelContext(modelContainer).fetch(
            FetchDescriptor<MessageRecord>(
                predicate: #Predicate { $0.conversationID == inboxID && $0.roleRaw == "watch-envelope" }
            )
        )
        .sorted { $0.ordinal < $1.ordinal }
        .compactMap(\.requestID)
        .suffix(max(limit, 0))
        .map { $0 }
    }

    func receiptCount() throws -> Int {
        try ModelContext(modelContainer).fetchCount(FetchDescriptor<WatchMessageReceiptRecord>())
    }

    func inboxMessageCount() throws -> Int {
        let inboxID = Self.conversationID
        return try ModelContext(modelContainer).fetchCount(
            FetchDescriptor<MessageRecord>(
                predicate: #Predicate { $0.conversationID == inboxID && $0.roleRaw == "watch-envelope" }
            )
        )
    }
}
