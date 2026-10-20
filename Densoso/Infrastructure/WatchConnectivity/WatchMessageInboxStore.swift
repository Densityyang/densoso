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
    private struct InboxMessageCursor {
        let ordinal: Int
        let id: UUID
    }

    static let conversationID = UUID(uuidString: "A7A81264-1866-4A0A-AF4A-78B920D5CB01")!
    private static let pendingReceiptFetchBatchSize = 64

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
        let messages = try pendingInboxMessages(in: context)
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
        let messages = try pendingInboxMessages(in: context)
        return messages.compactMap { message -> WatchMessageEnvelope? in
            guard message.requestID != nil,
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

    private func pendingInboxMessages(in context: ModelContext) throws -> [MessageRecord] {
        let pending = WatchReceiptState.pending
        let sortBy = [SortDescriptor(\WatchMessageReceiptRecord.messageID)]
        var cursorMessageID: String?
        var messages: [MessageRecord] = []
        while true {
            let predicate: Predicate<WatchMessageReceiptRecord>
            if let cursorMessageID {
                let lastMessageID = cursorMessageID
                predicate = #Predicate<WatchMessageReceiptRecord> { receipt in
                    receipt.state == pending && receipt.messageID > lastMessageID
                }
            } else {
                predicate = #Predicate<WatchMessageReceiptRecord> { $0.state == pending }
            }
            var descriptor = FetchDescriptor<WatchMessageReceiptRecord>(predicate: predicate, sortBy: sortBy)
            descriptor.fetchLimit = Self.pendingReceiptFetchBatchSize
            let receipts = try context.fetch(descriptor)
            guard let lastReceipt = receipts.last else { break }

            let messageIDs = receipts.compactMap { UUID(uuidString: $0.messageID) }
            messages.append(contentsOf: try pendingInboxMessages(matching: messageIDs, in: context))
            cursorMessageID = lastReceipt.messageID
            if receipts.count < Self.pendingReceiptFetchBatchSize { break }
        }
        return messages.sorted {
            $0.ordinal == $1.ordinal ? $0.id < $1.id : $0.ordinal < $1.ordinal
        }
    }

    private func pendingInboxMessages(
        matching messageIDs: [UUID],
        in context: ModelContext
    ) throws -> [MessageRecord] {
        guard !messageIDs.isEmpty else { return [] }
        let inboxID = Self.conversationID
        let role = "watch-envelope"
        let sortBy = [SortDescriptor(\MessageRecord.ordinal), SortDescriptor(\MessageRecord.id)]
        var cursor: InboxMessageCursor?
        var messages: [MessageRecord] = []
        while true {
            let predicate: Predicate<MessageRecord>
            if let cursor {
                let cursorOrdinal = cursor.ordinal
                let cursorID = cursor.id
                predicate = #Predicate<MessageRecord> { message in
                    message.conversationID == inboxID
                        && message.roleRaw == role
                        && message.requestID != nil
                        && messageIDs.contains(message.requestID!)
                        && (message.ordinal > cursorOrdinal
                            || (message.ordinal == cursorOrdinal && message.id > cursorID))
                }
            } else {
                predicate = #Predicate<MessageRecord> { message in
                    message.conversationID == inboxID
                        && message.roleRaw == role
                        && message.requestID != nil
                        && messageIDs.contains(message.requestID!)
                }
            }
            var descriptor = FetchDescriptor<MessageRecord>(predicate: predicate, sortBy: sortBy)
            descriptor.fetchLimit = Self.pendingReceiptFetchBatchSize
            let page = try context.fetch(descriptor)
            guard let lastMessage = page.last else { break }
            messages.append(contentsOf: page)
            cursor = InboxMessageCursor(ordinal: lastMessage.ordinal, id: lastMessage.id)
            if page.count < Self.pendingReceiptFetchBatchSize { break }
        }
        return messages
    }
}
