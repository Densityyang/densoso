import Foundation

public enum WatchSnapshotRequestCoalescingPolicy {
    public static func shouldEnqueue(pendingMessages: [WatchMessageEnvelope]) -> Bool {
        !pendingMessages.contains { envelope in
            if case .requestTodaySnapshot = envelope.payload { return true }
            return false
        }
    }
}
