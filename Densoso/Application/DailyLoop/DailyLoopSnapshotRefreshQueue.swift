import Foundation

/// Coalesces overlapping snapshot refresh requests without dropping newer state.
struct DailyLoopSnapshotRefreshQueue {
    enum Request: Equatable {
        case start(refreshHealth: Bool)
        case queued
    }

    private(set) var isRefreshing = false
    private var hasQueuedRefresh = false
    private var queuedRefreshesHealth = false

    mutating func request(refreshHealth: Bool) -> Request {
        guard !isRefreshing else {
            hasQueuedRefresh = true
            queuedRefreshesHealth = queuedRefreshesHealth || refreshHealth
            return .queued
        }

        isRefreshing = true
        return .start(refreshHealth: refreshHealth)
    }

    /// Finishes the current pass and returns the coalesced next pass, if any.
    mutating func finishPass() -> Bool? {
        guard hasQueuedRefresh else {
            isRefreshing = false
            return nil
        }

        hasQueuedRefresh = false
        let refreshHealth = queuedRefreshesHealth
        queuedRefreshesHealth = false
        return refreshHealth
    }
}
