import Foundation

enum PersistenceLifecycleError: Error, Equatable {
    case recoveryRequired
    case restoreInProgress
}

/// Quiesces persistence activity around store replacement. Nested work inherits
/// its parent operation lease, so an in-flight Agent/import can finish its own
/// writes after restore has stopped admitting new top-level operations.
@MainActor
final class PersistenceOperationBarrier {
    static let shared = PersistenceOperationBarrier()

    enum State: Equatable {
        case normal
        case quiescing
        case exclusiveRestore
        case recoveryRequired
        case resuming
    }

    enum Operation: Equatable {
        case outbox
        case healthImport
        case agentExecution
        case mutation
        case restore
    }

    struct Lease: Equatable {
        fileprivate let id: UUID
        fileprivate let barrierID: UUID
        fileprivate let operation: Operation
        fileprivate let isBorrowed: Bool
    }

    private struct Waiter {
        let id: UUID
        let operation: Operation
        let continuation: CheckedContinuation<Lease, Error>
    }

    @TaskLocal private static var currentLease: Lease?

    private let id = UUID()
    private var activeLeases: [UUID: Operation] = [:]
    private var waiters: [Waiter] = []
    private var restoreWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var state: State = .normal

    func acquireOutboxOperation() async throws -> Lease { try await acquire(.outbox) }
    func acquireHealthImportOperation() async throws -> Lease { try await acquire(.healthImport) }
    func acquireAgentExecutionOperation() async throws -> Lease { try await acquire(.agentExecution) }
    func acquireMutationOperation() async throws -> Lease { try await acquire(.mutation) }
    func acquireRestoreOperation() async throws -> Lease { try await acquire(.restore) }

    func withMutationOperation<T: Sendable>(
        operation: @isolated(any) @Sendable () async throws -> T
    ) async throws -> T {
        let lease = try await acquireMutationOperation()
        do {
            let result = try await Self.$currentLease.withValue(lease) {
                try await operation()
            }
            release(lease)
            return result
        } catch {
            release(lease)
            throw error
        }
    }

    func withLease<T>(_ lease: Lease, operation: () async throws -> T) async rethrows -> T {
        try await Self.$currentLease.withValue(lease) {
            try await operation()
        }
    }

    func release(_ lease: Lease) {
        guard lease.barrierID == id, !lease.isBorrowed else { return }
        guard activeLeases.removeValue(forKey: lease.id) != nil else { return }
        if lease.operation == .restore, state == .exclusiveRestore {
            state = waiters.contains(where: { $0.operation == .restore }) ? .quiescing : .resuming
            if state == .resuming { state = .normal }
        }
        drainWaiters()
    }

    func requireRecovery() {
        state = .recoveryRequired
        let rejected = waiters
        waiters.removeAll()
        rejected.forEach { $0.continuation.resume(throwing: PersistenceLifecycleError.recoveryRequired) }
        resumeRestoreQueueObservers()
        drainWaiters()
    }

    /// A deterministic synchronization point for persistence lifecycle tests.
    func waitUntilRestoreIsQueued() async {
        guard !waiters.contains(where: { $0.operation == .restore }) else { return }
        await withCheckedContinuation { continuation in
            if waiters.contains(where: { $0.operation == .restore }) {
                continuation.resume()
            } else {
                restoreWaiters.append(continuation)
            }
        }
    }

    private func acquire(_ operation: Operation) async throws -> Lease {
        try Task.checkCancellation()
        guard state != .recoveryRequired else {
            throw PersistenceLifecycleError.recoveryRequired
        }
        if operation != .restore,
           let inherited = Self.currentLease,
           inherited.barrierID == id,
           activeLeases[inherited.id] != nil {
            return Lease(id: inherited.id, barrierID: id, operation: operation, isBorrowed: true)
        }

        if operation == .restore {
            guard state != .exclusiveRestore else {
                return try await wait(for: operation)
            }
            state = .quiescing
            rejectQueuedNonRestoreOperations()
            resumeRestoreQueueObservers()
        } else {
            guard state == .normal,
                  !waiters.contains(where: { $0.operation == .restore }) else {
                throw PersistenceLifecycleError.restoreInProgress
            }
        }

        if canGrant(operation) {
            return grant(operation)
        }
        do {
            return try await wait(for: operation)
        } catch {
            // Restore changes admission state before it enters the waiter queue.
            // If cancellation wins before the continuation is enqueued,
            // cancelWaiter has nothing to remove, so unwind quiescing here too.
            if operation == .restore,
               state == .quiescing,
               !waiters.contains(where: { $0.operation == .restore }) {
                state = .normal
                drainWaiters()
            }
            throw error
        }
    }

    private func wait(for operation: Operation) async throws -> Lease {
        let waiterID = UUID()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Lease, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let waiter = Waiter(id: waiterID, operation: operation, continuation: continuation)
                if operation == .restore {
                    waiters.insert(waiter, at: 0)
                    resumeRestoreQueueObservers()
                } else {
                    waiters.append(waiter)
                }
                drainWaiters()
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(waiterID) }
        }
        if Task.isCancelled {
            release(lease)
            throw CancellationError()
        }
        return lease
    }

    private func canGrant(_ operation: Operation) -> Bool {
        switch operation {
        case .restore:
            return state == .quiescing && activeLeases.isEmpty
        case .outbox, .healthImport:
            return state == .normal
                && !waiters.contains(where: { $0.operation == .restore })
                && !activeLeases.values.contains(operation)
        case .agentExecution, .mutation:
            return state == .normal && !waiters.contains(where: { $0.operation == .restore })
        }
    }

    private func grant(_ operation: Operation) -> Lease {
        let lease = Lease(id: UUID(), barrierID: id, operation: operation, isBorrowed: false)
        activeLeases[lease.id] = operation
        if operation == .restore { state = .exclusiveRestore }
        return lease
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        if waiter.operation == .restore,
           state == .quiescing,
           !waiters.contains(where: { $0.operation == .restore }) {
            state = .normal
        }
        drainWaiters()
    }

    private func drainWaiters() {
        if state == .quiescing {
            guard activeLeases.isEmpty,
                  let index = waiters.firstIndex(where: { $0.operation == .restore }) else { return }
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: grant(.restore))
            return
        }
        guard state == .normal else { return }
        while let index = waiters.firstIndex(where: { $0.operation != .restore && canGrant($0.operation) }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: grant(waiter.operation))
        }
    }

    private func resumeRestoreQueueObservers() {
        guard !restoreWaiters.isEmpty else { return }
        let observers = restoreWaiters
        restoreWaiters.removeAll()
        observers.forEach { $0.resume() }
    }

    private func rejectQueuedNonRestoreOperations() {
        let rejected = waiters.filter { $0.operation != .restore }
        waiters.removeAll { $0.operation != .restore }
        rejected.forEach { $0.continuation.resume(throwing: PersistenceLifecycleError.restoreInProgress) }
    }
}
