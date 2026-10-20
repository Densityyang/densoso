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

    func nextEligibleTranscript(excluding claimedIDs: Set<UUID> = []) throws -> PendingWatchTranscript? {
        let context = ModelContext(modelContainer)
        let messages = try pendingInboxMessages(in: context)
        let pendingEnvelopes = messages.compactMap { try? WatchMessageCodec.decode($0.contentData) }
        let states = try causalSequenceStates(for: pendingEnvelopes)
        let earlierPendingIDs = Set(messages.compactMap(\.requestID))
        let transcripts = messages.compactMap { message -> (WatchMessageEnvelope, PendingWatchTranscript)? in
            guard let id = message.requestID,
                  !claimedIDs.contains(id),
                  let envelope = try? WatchMessageCodec.decode(message.contentData),
                  case .transcript(let text) = envelope.payload,
                  WatchCommandDependencyPolicy.decision(for: envelope, sequenceStates: states) == .ready,
                  states[envelope.causalSequence ?? -1] != .conflict,
                  !hasEarlierPendingCommand(
                    before: message,
                    messages: messages,
                    pendingIDs: earlierPendingIDs,
                    currentSequence: envelope.causalSequence
                  ) else { return nil }
            return (envelope, PendingWatchTranscript(messageID: id, text: text))
        }
        return WatchCommandOrderingPolicy.replayOrder(transcripts.map(\.0))
            .compactMap { ordered in transcripts.first(where: { $0.0.messageID == ordered.messageID })?.1 }
            .first
    }

    func pendingCommandEnvelopes() throws -> [WatchMessageEnvelope] {
        let context = ModelContext(modelContainer)
        let messages = try pendingInboxMessages(in: context)
        let envelopes = messages.compactMap { message -> WatchMessageEnvelope? in
            guard message.requestID != nil,
                  let envelope = try? WatchMessageCodec.decode(message.contentData) else { return nil }
            if case .transcript = envelope.payload { return nil }
            return envelope
        }
        return WatchCommandOrderingPolicy.replayOrder(envelopes)
    }

    func pendingReplayEnvelopes() throws -> [WatchMessageEnvelope] {
        let context = ModelContext(modelContainer)
        let messages = try pendingInboxMessages(in: context)
        let envelopes = messages.compactMap { message -> WatchMessageEnvelope? in
            guard message.requestID != nil,
                  let envelope = try? WatchMessageCodec.decode(message.contentData) else { return nil }
            return envelope
        }
        return WatchCommandOrderingPolicy.replayOrder(envelopes)
    }

    func causalSequenceStates() throws -> [Int: WatchCommandSequenceState] {
        var sequences = Set<Int>()
        try forEachInboxMessage { message in
            guard let envelope = try? WatchMessageCodec.decode(message.contentData),
                  let sequence = envelope.causalSequence else { return }
            _ = sequences.insert(sequence)
        }
        return try causalSequenceStates(for: sequences)
    }

    func causalSequenceStates(for envelopes: [WatchMessageEnvelope]) throws -> [Int: WatchCommandSequenceState] {
        let sequences = Set(envelopes.flatMap { envelope in
            [envelope.causalSequence, envelope.dependsOn].compactMap { $0 }
        })
        return try causalSequenceStates(for: sequences)
    }

    private func causalSequenceStates(for sequences: Set<Int>) throws -> [Int: WatchCommandSequenceState] {
        guard !sequences.isEmpty else { return [:] }

        var messageIDBySequence: [Int: String] = [:]
        var duplicateSequences = Set<Int>()
        try forEachInboxMessage { message in
            guard let requestID = message.requestID,
                  let envelope = try? WatchMessageCodec.decode(message.contentData),
                  let sequence = envelope.causalSequence,
                  sequences.contains(sequence),
                  !duplicateSequences.contains(sequence) else { return }
            if messageIDBySequence[sequence] != nil {
                messageIDBySequence.removeValue(forKey: sequence)
                duplicateSequences.insert(sequence)
            } else {
                messageIDBySequence[sequence] = requestID.uuidString.lowercased()
            }
        }

        let requestedIDs = messageIDBySequence.values.sorted()
        let context = ModelContext(modelContainer)
        var receiptStates: [String: WatchCommandSequenceState] = [:]
        var offset = 0
        while offset < requestedIDs.count {
            let batchEnd = min(offset + Self.pendingReceiptFetchBatchSize, requestedIDs.count)
            let batchIDs = Array(requestedIDs[offset..<batchEnd])
            let predicate = #Predicate<WatchMessageReceiptRecord> {
                batchIDs.contains($0.messageID)
            }
            for receipt in try context.fetch(FetchDescriptor<WatchMessageReceiptRecord>(predicate: predicate)) {
                switch receipt.state {
                case WatchReceiptState.pending:
                    receiptStates[receipt.messageID] = .pending
                case WatchReceiptState.processed:
                    receiptStates[receipt.messageID] = .processed
                case WatchReceiptState.rejected:
                    receiptStates[receipt.messageID] = .rejected
                default:
                    receiptStates[receipt.messageID] = .pending
                }
            }
            offset = batchEnd
        }

        var states: [Int: WatchCommandSequenceState] = [:]
        for sequence in sequences {
            if duplicateSequences.contains(sequence) {
                states[sequence] = .conflict
            } else if let messageID = messageIDBySequence[sequence] {
                states[sequence] = receiptStates[messageID] ?? .pending
            }
        }
        return states
    }

    func hasEarlierPendingCommand(before messageID: UUID) throws -> Bool {
        let context = ModelContext(modelContainer)
        let messages = try pendingInboxMessages(in: context)
        let pendingIDs = Set(messages.compactMap(\.requestID))
        guard let current = messages.first(where: { $0.requestID == messageID }) else { return false }
        let currentSequence = (try? WatchMessageCodec.decode(current.contentData))?.causalSequence
        return hasEarlierPendingCommand(
            before: current,
            messages: messages,
            pendingIDs: pendingIDs,
            currentSequence: currentSequence
        )
    }

    private func hasEarlierPendingCommand(
        before current: MessageRecord,
        messages: [MessageRecord],
        pendingIDs: Set<UUID>,
        currentSequence: Int?
    ) -> Bool {
        for message in messages where message.ordinal < current.ordinal
            || (message.ordinal == current.ordinal && message.id < current.id) {
            guard let requestID = message.requestID,
                  pendingIDs.contains(requestID),
                  let envelope = try? WatchMessageCodec.decode(message.contentData) else { continue }
            switch envelope.payload {
            case .transcript, .confirm, .reject:
                // A later-arriving lower sequence must be allowed to repair an
                // out-of-order delivery. Legacy work has no sequence and keeps
                // its durable arrival-order barrier.
                if let currentSequence,
                   let earlierSequence = envelope.causalSequence,
                   earlierSequence > currentSequence {
                    continue
                }
                return true
            case .requestTodaySnapshot, .acknowledgement, .todaySnapshot:
                continue
            }
        }
        return false
    }

    @discardableResult
    func setState(_ state: String, for messageID: UUID) throws -> Int? {
        let context = ModelContext(modelContainer)
        let key = messageID.uuidString.lowercased()
        let predicate = #Predicate<WatchMessageReceiptRecord> { $0.messageID == key }
        var descriptor = FetchDescriptor<WatchMessageReceiptRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let receipt = try context.fetch(descriptor).first else { return nil }
        let inboxID = Self.conversationID
        let role = "watch-envelope"
        let messagePredicate = #Predicate<MessageRecord> { message in
            message.conversationID == inboxID && message.roleRaw == role && message.requestID == messageID
        }
        var messageDescriptor = FetchDescriptor<MessageRecord>(predicate: messagePredicate)
        messageDescriptor.fetchLimit = 1
        let causalSequence = try context.fetch(messageDescriptor).first
            .flatMap { try? WatchMessageCodec.decode($0.contentData).causalSequence }
        receipt.state = state
        receipt.processedAt = Date()
        try context.save()
        return causalSequence
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

    func highestContiguousTerminalCausalSequence() throws -> Int? {
        var terminalBySequence: [Int: Bool] = [:]
        var receiptBatch: [(sequence: Int, messageID: String)] = []
        let receiptContext = ModelContext(modelContainer)

        func consumeReceiptBatch(_ entries: [(sequence: Int, messageID: String)]) throws {
            let messageIDs = Array(Set(entries.map { $0.messageID })).sorted()
            var terminalByMessageID: [String: Bool] = [:]
            var offset = 0
            while offset < messageIDs.count {
                let batchEnd = min(offset + Self.pendingReceiptFetchBatchSize, messageIDs.count)
                let batchIDs = Array(messageIDs[offset..<batchEnd])
                let predicate = #Predicate<WatchMessageReceiptRecord> {
                    batchIDs.contains($0.messageID)
                }
                for receipt in try receiptContext.fetch(FetchDescriptor<WatchMessageReceiptRecord>(predicate: predicate)) {
                    terminalByMessageID[receipt.messageID] =
                        receipt.state == WatchReceiptState.processed || receipt.state == WatchReceiptState.rejected
                }
                offset = batchEnd
            }

            for entry in entries {
                let isTerminal = terminalByMessageID[entry.messageID] ?? false
                if let priorState = terminalBySequence[entry.sequence] {
                    terminalBySequence[entry.sequence] = priorState && isTerminal
                } else {
                    terminalBySequence[entry.sequence] = isTerminal
                }
            }
        }

        try forEachInboxMessage { message in
            guard let messageID = message.requestID,
                  let envelope = try? WatchMessageCodec.decode(message.contentData),
                  let sequence = envelope.causalSequence else { return }
            receiptBatch.append((sequence, messageID.uuidString.lowercased()))
            if receiptBatch.count == Self.pendingReceiptFetchBatchSize {
                try consumeReceiptBatch(receiptBatch)
                receiptBatch.removeAll(keepingCapacity: true)
            }
        }
        if !receiptBatch.isEmpty { try consumeReceiptBatch(receiptBatch) }

        var highestTerminalSequence: Int?
        var sequence = 1
        while terminalBySequence[sequence] == true {
            highestTerminalSequence = sequence
            guard sequence < Int.max else { break }
            sequence += 1
        }
        return highestTerminalSequence
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
        let pendingIDs = try pendingMessageIDs(in: context)
        guard !pendingIDs.isEmpty else { return [] }

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
                        && (message.ordinal > cursorOrdinal
                            || (message.ordinal == cursorOrdinal && message.id > cursorID))
                }
            } else {
                predicate = #Predicate<MessageRecord> { message in
                    message.conversationID == inboxID && message.roleRaw == role
                }
            }
            var descriptor = FetchDescriptor<MessageRecord>(predicate: predicate, sortBy: sortBy)
            descriptor.fetchLimit = Self.pendingReceiptFetchBatchSize
            let page = try context.fetch(descriptor)
            guard let lastMessage = page.last else { break }
            messages.append(contentsOf: page.filter { message in
                guard let requestID = message.requestID else { return false }
                return pendingIDs.contains(requestID)
            })
            cursor = InboxMessageCursor(ordinal: lastMessage.ordinal, id: lastMessage.id)
            if page.count < Self.pendingReceiptFetchBatchSize { break }
        }
        return messages.sorted {
            $0.ordinal == $1.ordinal ? $0.id < $1.id : $0.ordinal < $1.ordinal
        }
    }

    private func forEachInboxMessage(_ body: (MessageRecord) throws -> Void) throws {
        let context = ModelContext(modelContainer)
        let inboxID = Self.conversationID
        let role = "watch-envelope"
        let sortBy = [SortDescriptor(\.ordinal), SortDescriptor(\.id)]
        var cursor: InboxMessageCursor?
        while true {
            let predicate: Predicate<MessageRecord>
            if let cursor {
                let cursorOrdinal = cursor.ordinal
                let cursorID = cursor.id
                predicate = #Predicate<MessageRecord> { message in
                    message.conversationID == inboxID
                        && message.roleRaw == role
                        && (message.ordinal > cursorOrdinal
                            || (message.ordinal == cursorOrdinal && message.id > cursorID))
                }
            } else {
                predicate = #Predicate<MessageRecord> { message in
                    message.conversationID == inboxID && message.roleRaw == role
                }
            }
            var descriptor = FetchDescriptor<MessageRecord>(predicate: predicate, sortBy: sortBy)
            descriptor.fetchLimit = Self.pendingReceiptFetchBatchSize
            let page = try context.fetch(descriptor)
            guard let lastMessage = page.last else { break }
            for message in page { try body(message) }
            cursor = InboxMessageCursor(ordinal: lastMessage.ordinal, id: lastMessage.id)
            if page.count < Self.pendingReceiptFetchBatchSize { break }
        }
    }

    private func pendingMessageIDs(in context: ModelContext) throws -> Set<UUID> {
        let pending = WatchReceiptState.pending
        let sortBy = [SortDescriptor(\WatchMessageReceiptRecord.messageID)]
        var cursorMessageID: String?
        var pendingIDs = Set<UUID>()
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

            pendingIDs.formUnion(receipts.compactMap { UUID(uuidString: $0.messageID) })
            cursorMessageID = lastReceipt.messageID
            if receipts.count < Self.pendingReceiptFetchBatchSize { break }
        }
        return pendingIDs
    }
}
