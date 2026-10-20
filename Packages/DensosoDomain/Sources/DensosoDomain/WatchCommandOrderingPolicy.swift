import Foundation

public enum WatchCommandSequenceState: Equatable, Sendable {
    case pending
    case processed
    case rejected
    case conflict
}

public enum WatchCommandDependencyDecision: Equatable, Sendable {
    case ready
    case waitingFor(Int)
    case rejectedBecause(Int)
}

public enum WatchCommandDependencyPolicy {
    public static func decision(
        for envelope: WatchMessageEnvelope,
        sequenceStates: [Int: WatchCommandSequenceState]
    ) -> WatchCommandDependencyDecision {
        guard let dependency = envelope.dependsOn else { return .ready }
        switch sequenceStates[dependency] {
        case .some(.processed):
            return .ready
        case .some(.rejected), .some(.conflict):
            return .rejectedBecause(dependency)
        case .some(.pending), .none:
            return .waitingFor(dependency)
        }
    }
}

public enum WatchCommandOrderingPolicy {
    /// Orders new sequenced commands by causal sequence while retaining legacy
    /// outbox messages in their existing timestamp/message-ID order.
    public static func dispatchOrder(_ envelopes: [WatchMessageEnvelope]) -> [WatchMessageEnvelope] {
        let legacy = envelopes.filter { $0.causalSequence == nil }.sorted(by: arrivalOrder)
        let sequenced = envelopes.filter { $0.causalSequence != nil }.sorted(by: causalOrder)
        return merge(legacy, sequenced, isLegacyBeforeSequenced: { arrivalOrder($0, $1) })
    }

    /// The input is already in durable inbox arrival order. Sequence-order new
    /// commands, but preserve the arrival order of legacy messages and merge
    /// both streams without moving either stream past its own predecessor.
    public static func replayOrder(_ envelopes: [WatchMessageEnvelope]) -> [WatchMessageEnvelope] {
        let indexed = Array(envelopes.enumerated())
        let legacy = indexed.filter { $0.element.causalSequence == nil }
        let sequenced = indexed.filter { $0.element.causalSequence != nil }.sorted { lhs, rhs in
            if lhs.element.causalSequence != rhs.element.causalSequence {
                return causalOrder(lhs.element, rhs.element)
            }
            return lhs.offset < rhs.offset
        }
        var legacyIndex = 0
        var sequenceIndex = 0
        var ordered: [WatchMessageEnvelope] = []
        ordered.reserveCapacity(envelopes.count)

        while legacyIndex < legacy.count && sequenceIndex < sequenced.count {
            if legacy[legacyIndex].offset < sequenced[sequenceIndex].offset {
                ordered.append(legacy[legacyIndex].element)
                legacyIndex += 1
            } else {
                ordered.append(sequenced[sequenceIndex].element)
                sequenceIndex += 1
            }
        }
        if legacyIndex < legacy.count { ordered.append(contentsOf: legacy[legacyIndex...].map { $0.element }) }
        if sequenceIndex < sequenced.count { ordered.append(contentsOf: sequenced[sequenceIndex...].map { $0.element }) }
        return ordered
    }

    private static func merge(
        _ legacy: [WatchMessageEnvelope],
        _ sequenced: [WatchMessageEnvelope],
        isLegacyBeforeSequenced: (WatchMessageEnvelope, WatchMessageEnvelope) -> Bool
    ) -> [WatchMessageEnvelope] {
        var legacyIndex = 0
        var sequenceIndex = 0
        var ordered: [WatchMessageEnvelope] = []
        ordered.reserveCapacity(legacy.count + sequenced.count)

        while legacyIndex < legacy.count && sequenceIndex < sequenced.count {
            if isLegacyBeforeSequenced(legacy[legacyIndex], sequenced[sequenceIndex]) {
                ordered.append(legacy[legacyIndex])
                legacyIndex += 1
            } else {
                ordered.append(sequenced[sequenceIndex])
                sequenceIndex += 1
            }
        }
        if legacyIndex < legacy.count { ordered.append(contentsOf: legacy[legacyIndex...]) }
        if sequenceIndex < sequenced.count { ordered.append(contentsOf: sequenced[sequenceIndex...]) }
        return ordered
    }

    private static func causalOrder(_ lhs: WatchMessageEnvelope, _ rhs: WatchMessageEnvelope) -> Bool {
        let leftSequence = lhs.causalSequence ?? Int.max
        let rightSequence = rhs.causalSequence ?? Int.max
        if leftSequence != rightSequence { return leftSequence < rightSequence }
        return arrivalOrder(lhs, rhs)
    }

    private static func arrivalOrder(_ lhs: WatchMessageEnvelope, _ rhs: WatchMessageEnvelope) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.messageID.uuidString < rhs.messageID.uuidString
    }
}
