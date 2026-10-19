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
    private static let missingRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

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
            let receiptPredicate = #Predicate<WatchMessageReceiptRecord> { $0.messageID == key }
            var receiptDescriptor = FetchDescriptor<WatchMessageReceiptRecord>(predicate: receiptPredicate)
            receiptDescriptor.fetchLimit = 1
            if let receipt = try context.fetch(receiptDescriptor).first {
                if receipt.payloadHash != payloadHash {
                    result = .payloadConflict
                } else if receipt.state == WatchReceiptState.processed || receipt.state == WatchReceiptState.rejected {
                    result = .duplicateProcessed
                } else {
                    result = .duplicatePending
                }
                return
            }

            let inboxID = Self.conversationID
            let conversationPredicate = #Predicate<ConversationRecord> { $0.id == inboxID }
            var conversationDescriptor = FetchDescriptor<ConversationRecord>(predicate: conversationPredicate)
            conversationDescriptor.fetchLimit = 1
            if try context.fetch(conversationDescriptor).first == nil {
                context.insert(ConversationRecord(
                    id: Self.conversationID,
                    state: "watchInbox",
                    title: "Watch Inbox"
                ))
            }
            let messagePredicate = #Predicate<MessageRecord> { $0.conversationID == inboxID }
            var messageDescriptor = FetchDescriptor<MessageRecord>(
                predicate: messagePredicate,
                sortBy: [SortDescriptor(\.ordinal, order: .reverse)]
            )
            messageDescriptor.fetchLimit = 1
            let lastOrdinal = try context.fetch(messageDescriptor).first?.ordinal ?? -1
            context.insert(MessageRecord(
                conversationID: Self.conversationID,
                roleRaw: "watch-envelope",
                contentData: data,
                ordinal: lastOrdinal + 1,
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
        let pendingIDs = try pendingMessageIDs(in: context)
        let messages = try pendingInboxMessages(matching: pendingIDs, in: context)
        return messages.compactMap { message -> PendingWatchTranscript? in
            guard let id = message.requestID,
                  !claimedIDs.contains(id),
                  let envelope = try? WatchMessageCodec.decode(message.contentData),
                  case .transcript(let text) = envelope.payload else { return nil }
            return PendingWatchTranscript(messageID: id, text: text)
        }
    }

    func pendingCommandEnvelopes() throws -> [WatchMessageEnvelope] {
        let context = ModelContext(modelContainer)
        let pendingIDs = try pendingMessageIDs(in: context)
        let messages = try pendingInboxMessages(matching: pendingIDs, in: context)
        return messages.compactMap { message -> WatchMessageEnvelope? in
            guard let id = message.requestID,
                  let envelope = try? WatchMessageCodec.decode(message.contentData) else { return nil }
            if case .transcript = envelope.payload { return nil }
            return envelope
        }
    }

    func setState(_ state: String, for messageID: UUID) throws {
        let context = ModelContext(modelContainer)
        let key = messageID.uuidString.lowercased()
        let predicate = #Predicate<WatchMessageReceiptRecord> { $0.messageID == key }
        var descriptor = FetchDescriptor<WatchMessageReceiptRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let receipt = try context.fetch(descriptor).first else { return }
        receipt.state = state
        receipt.processedAt = Date()
        try context.save()
    }

    func recentProcessedMessageIDs(limit: Int = 100) throws -> [UUID] {
        let boundedLimit = max(limit, 0)
        guard boundedLimit > 0 else { return [] }
        let context = ModelContext(modelContainer)
        let processed = WatchReceiptState.processed
        let rejected = WatchReceiptState.rejected
        let predicate = #Predicate<WatchMessageReceiptRecord> {
            $0.state == processed || $0.state == rejected
        }
        var descriptor = FetchDescriptor<WatchMessageReceiptRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.processedAt, order: .reverse)]
        )
        descriptor.fetchLimit = boundedLimit
        return try context.fetch(descriptor)
            .reversed()
            .compactMap { UUID(uuidString: $0.messageID) }
    }

    func recentReceivedMessageIDs(limit: Int = 100) throws -> [UUID] {
        let boundedLimit = max(limit, 0)
        guard boundedLimit > 0 else { return [] }
        let inboxID = Self.conversationID
        let role = "watch-envelope"
        let predicate = #Predicate<MessageRecord> { $0.conversationID == inboxID && $0.roleRaw == role }
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.ordinal, order: .reverse)]
        )
        descriptor.fetchLimit = boundedLimit
        return try ModelContext(modelContainer).fetch(descriptor)
            .reversed()
            .compactMap(\.requestID)
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

    private func pendingMessageIDs(in context: ModelContext) throws -> [UUID] {
        let pending = WatchReceiptState.pending
        let predicate = #Predicate<WatchMessageReceiptRecord> { $0.state == pending }
        return try context.fetch(FetchDescriptor<WatchMessageReceiptRecord>(predicate: predicate))
            .compactMap { UUID(uuidString: $0.messageID) }
    }

    private func pendingInboxMessages(
        matching messageIDs: [UUID],
        in context: ModelContext
    ) throws -> [MessageRecord] {
        guard !messageIDs.isEmpty else { return [] }
        let inboxID = Self.conversationID
        let role = "watch-envelope"
        let missingRequestID = Self.missingRequestID
        let predicate = #Predicate<MessageRecord> {
            $0.conversationID == inboxID &&
                $0.roleRaw == role &&
                messageIDs.contains($0.requestID ?? missingRequestID)
        }
        return try context.fetch(FetchDescriptor<MessageRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.ordinal)]
        ))
    }
}
