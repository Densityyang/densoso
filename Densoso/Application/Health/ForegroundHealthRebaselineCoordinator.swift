import DensosoDomain
import Foundation

enum ForegroundHealthRebaselineState: Equatable {
    case idle
    case preparing(generation: UInt64)
    case syncing(generation: UInt64)
    case queued(generation: UInt64)
    case completed(generation: UInt64)
    case partiallyCompleted(generation: UInt64, failedStreams: Set<HealthMetricID>)
    case failed(generation: UInt64, diagnostic: String)
    case superseded(generation: UInt64)
}

/// Owns one foreground rebaseline lifecycle at a time. Preparation and sync
/// are one operation, and a newer foreground activation is queued behind it.
@MainActor
final class ForegroundHealthRebaselineCoordinator {
    typealias SyncPhaseHandler = @MainActor () -> Void
    typealias Operation = @MainActor (Bool, SyncPhaseHandler) async throws -> HealthSyncResult

    private let operation: Operation
    private let retryDelayNanoseconds: @MainActor (Int) -> UInt64
    private var isForegroundActive = false
    private var activationGeneration: UInt64 = 0
    private var runnerGeneration: UInt64?
    private var queuedGeneration: UInt64?
    private var completedGeneration: UInt64?
    private var fullRebaselineCompletedGeneration: UInt64?
    private var runnerTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var retryNotBefore: Date?

    private(set) var state: ForegroundHealthRebaselineState = .idle
    private(set) var pendingFailedStreams: Set<HealthMetricID> = []

    init(
        retryDelayNanoseconds: (@MainActor (Int) -> UInt64)? = nil,
        operation: @escaping Operation
    ) {
        self.retryDelayNanoseconds = retryDelayNanoseconds ?? { attempt in
            let exponent = min(max(attempt - 1, 0), 5)
            let seconds = min(30 * (1 << exponent), 15 * 60)
            return UInt64(seconds) * 1_000_000_000
        }
        self.operation = operation
    }

    /// Repeated calls during one active scene join the same run. A new scene
    /// activation gets its own generation and waits for any older run to end.
    func prepareActivation(onNewGeneration: @MainActor () -> Void = {}) {
        guard !isForegroundActive else { return }
        isForegroundActive = true
        activationGeneration &+= 1
        completedGeneration = nil
        fullRebaselineCompletedGeneration = nil
        pendingFailedStreams = []
        onNewGeneration()
    }

    func activate() async {
        prepareActivation()
        await requestCurrentActivation()
    }

    func deactivate() {
        isForegroundActive = false
    }

    /// Starts a fresh full synchronization after a dataset replacement even
    /// when the current foreground activation had already completed.
    func rebaselineAfterDatasetRestore() async {
        isForegroundActive = true
        activationGeneration &+= 1
        completedGeneration = nil
        fullRebaselineCompletedGeneration = nil
        pendingFailedStreams = []
        retryTask?.cancel()
        retryTask = nil
        retryNotBefore = nil
        await requestCurrentActivation()
    }

    private func requestCurrentActivation() async {
        guard isForegroundActive else { return }
        let requestedGeneration = activationGeneration
        guard completedGeneration != requestedGeneration else { return }

        if let runnerTask {
            if runnerGeneration != requestedGeneration {
                queuedGeneration = requestedGeneration
                state = .queued(generation: requestedGeneration)
            }
            await runnerTask.value
            return
        }

        if retryTask != nil {
            return
        }
        if let retryNotBefore, retryNotBefore > Date() {
            scheduleRetry(after: retryNotBefore.timeIntervalSinceNow)
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainQueue(startingWith: requestedGeneration)
            self.runnerTask = nil
            self.runnerGeneration = nil
        }
        runnerGeneration = requestedGeneration
        runnerTask = task
        await task.value
    }

    private func drainQueue(startingWith firstGeneration: UInt64) async {
        var generation = firstGeneration
        while true {
            let shouldRetry = await performAttempt(generation: generation)
            if let queuedGeneration {
                self.queuedGeneration = nil
                generation = queuedGeneration
                guard isForegroundActive else { return }
                continue
            }
            if shouldRetry, isForegroundActive, generation == activationGeneration {
                scheduleRetry(after: nil)
            }
            return
        }
    }

    private func performAttempt(generation: UInt64) async -> Bool {
        guard isForegroundActive, generation == activationGeneration else {
            if !isForegroundActive { state = .superseded(generation: generation) }
            return false
        }

        let requiresFullRebaseline = fullRebaselineCompletedGeneration != generation
        state = .preparing(generation: generation)
        do {
            let result = try await operation(requiresFullRebaseline) { [weak self] in
                guard let self,
                      self.isForegroundActive,
                      self.activationGeneration == generation else { return }
                self.state = .syncing(generation: generation)
            }
            if requiresFullRebaseline {
                fullRebaselineCompletedGeneration = generation
            }
            guard isForegroundActive, activationGeneration == generation else {
                if !isForegroundActive { state = .superseded(generation: generation) }
                return false
            }
            pendingFailedStreams.formUnion(result.failedStreams.keys)
            pendingFailedStreams.subtract(result.completedStreams)
            guard !result.hasFailures else {
                state = .partiallyCompleted(
                    generation: generation,
                    failedStreams: pendingFailedStreams
                )
                return true
            }

            state = .completed(generation: generation)
            completedGeneration = generation
            retryAttempt = 0
            retryNotBefore = nil
            retryTask?.cancel()
            retryTask = nil
            return false
        } catch is HealthSyncSupersededError {
            guard activationGeneration == generation else { return false }
            guard isForegroundActive else {
                state = .superseded(generation: generation)
                return false
            }
            pendingFailedStreams = HealthKitSyncCoordinator.observedStreams
            state = .superseded(generation: generation)
            return true
        } catch {
            guard activationGeneration == generation else { return false }
            guard isForegroundActive else {
                state = .superseded(generation: generation)
                return false
            }
            pendingFailedStreams = HealthKitSyncCoordinator.observedStreams
            let fallback = SharedErrorDescriptor(
                code: .projectionFailed,
                userMessage: "健康数据暂时无法重新同步。",
                subsystem: .healthKit,
                reason: .healthKitQueryFailed
            )
            state = .failed(
                generation: generation,
                diagnostic: SharedErrorDescriptor.mapped(from: error, fallback: fallback).diagnosticSafeDetail
            )
            return true
        }
    }

    private func scheduleRetry(after explicitDelay: TimeInterval?) {
        guard retryTask == nil else { return }
        retryAttempt += 1
        let delay = max(explicitDelay ?? Double(retryDelayNanoseconds(retryAttempt)) / 1_000_000_000, 0)
        retryNotBefore = Date().addingTimeInterval(delay)
        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            self.retryTask = nil
            guard self.isForegroundActive else { return }
            await self.requestCurrentActivation()
        }
    }

}
