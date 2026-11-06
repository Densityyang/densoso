import DensosoDomain
import XCTest
@testable import Densoso

@MainActor
final class ForegroundHealthRebaselineCoordinatorTests: XCTestCase {
    func testRepeatedPrepareAfterCompletedActivationDoesNotRecloseExportGate() async throws {
        let gate = HealthContextExportGate(initiallyOpen: true)
        var preparationCount = 0
        let coordinator = ForegroundHealthRebaselineCoordinator(
            operation: { _, _ in
                let holdToken = gate.foregroundPurgeHoldToken
                let purgeGeneration = gate.closeForSnapshotRebuild()
                gate.openAfterSuccessfulPurge(generation: purgeGeneration)
                gate.releaseForegroundPurgeHoldAfterSuccessfulSnapshotRebuild(holdToken)
                return Self.successfulResult
            }
        )
        let prepareExportGate: @MainActor () -> Void = {
            preparationCount += 1
            gate.closeForForegroundActivation(hasRequestedAuthorization: true)
        }

        coordinator.prepareActivation(onNewGeneration: prepareExportGate)
        await coordinator.activate()
        XCTAssertEqual(preparationCount, 1)
        XCTAssertEqual(coordinator.foregroundRebaselineAttemptCount, 1)
        XCTAssertTrue(gate.isOpen)
        XCTAssertNil(gate.foregroundPurgeHoldToken)

        coordinator.prepareActivation(onNewGeneration: prepareExportGate)
        await coordinator.activate()

        XCTAssertEqual(preparationCount, 1)
        XCTAssertEqual(coordinator.foregroundRebaselineAttemptCount, 1)
        XCTAssertTrue(gate.isOpen)
        XCTAssertNil(gate.foregroundPurgeHoldToken)
    }

    func testBackgroundToForegroundPreparationCreatesANewExportGateHold() async throws {
        let gate = HealthContextExportGate(initiallyOpen: true)
        let coordinator = ForegroundHealthRebaselineCoordinator(
            operation: { _, _ in
                let holdToken = gate.foregroundPurgeHoldToken
                let purgeGeneration = gate.closeForSnapshotRebuild()
                gate.openAfterSuccessfulPurge(generation: purgeGeneration)
                gate.releaseForegroundPurgeHoldAfterSuccessfulSnapshotRebuild(holdToken)
                return Self.successfulResult
            }
        )
        let prepareExportGate: @MainActor () -> Void = {
            gate.closeForForegroundActivation(hasRequestedAuthorization: true)
        }

        coordinator.prepareActivation(onNewGeneration: prepareExportGate)
        await coordinator.activate()
        XCTAssertTrue(gate.isOpen)
        XCTAssertNil(gate.foregroundPurgeHoldToken)

        coordinator.deactivate()
        coordinator.prepareActivation(onNewGeneration: prepareExportGate)

        XCTAssertFalse(gate.isOpen)
        let secondHoldToken = try XCTUnwrap(gate.foregroundPurgeHoldToken)
        await coordinator.activate()
        XCTAssertTrue(gate.isOpen)
        XCTAssertNil(gate.foregroundPurgeHoldToken)
        XCTAssertNotEqual(secondHoldToken, 0)
        XCTAssertEqual(coordinator.foregroundRebaselineAttemptCount, 2)
    }

    func testRepeatedActivationDuringPreparationRunsOneFullRebaseline() async throws {
        var calls = 0
        var releasePreparation: CheckedContinuation<HealthSyncResult, Error>?
        let coordinator = ForegroundHealthRebaselineCoordinator(
            retryDelayNanoseconds: { _ in 0 },
            operation: { _, _ in
                calls += 1
                return try await withCheckedThrowingContinuation { continuation in
                    releasePreparation = continuation
                }
            }
        )

        let firstActivation = Task { @MainActor in await coordinator.activate() }
        try await waitUntil { calls == 1 }
        let duplicateActivation = Task { @MainActor in await coordinator.activate() }
        await Task.yield()
        XCTAssertEqual(calls, 1)

        releasePreparation?.resume(returning: Self.successfulResult)
        await firstActivation.value
        await duplicateActivation.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(coordinator.state, .completed(generation: 1))
    }

    func testDatasetRestoreRequestsAnotherFullRebaselineInSameForegroundSession() async throws {
        var fullRebaselineArguments: [Bool] = []
        let coordinator = ForegroundHealthRebaselineCoordinator(
            operation: { requiresFullRebaseline, _ in
                fullRebaselineArguments.append(requiresFullRebaseline)
                return Self.successfulResult
            }
        )

        await coordinator.activate()
        XCTAssertEqual(coordinator.state, .completed(generation: 1))
        await coordinator.rebaselineAfterDatasetRestore()

        XCTAssertEqual(fullRebaselineArguments, [true, true])
        XCTAssertEqual(coordinator.state, .completed(generation: 2))
        XCTAssertEqual(coordinator.foregroundRebaselineAttemptCount, 2)
    }

    func testPartialFailureIsRetriedIncrementallyWithoutLosingSuccessfulStreams() async throws {
        var fullRebaselineArguments: [Bool] = []
        var callCount = 0
        let coordinator = ForegroundHealthRebaselineCoordinator(
            retryDelayNanoseconds: { _ in 1_000_000 },
            operation: { requiresFullRebaseline, _ in
                callCount += 1
                fullRebaselineArguments.append(requiresFullRebaseline)
                if callCount == 1 {
                    return HealthSyncResult(
                        completedStreams: [.stepCount, .sleepAnalysis],
                        failedStreams: [.heartRate: Self.failure(.heartRate)]
                    )
                }
                return Self.successfulResult
            }
        )

        await coordinator.activate()
        try await waitUntil {
            if case .completed = coordinator.state { return true }
            return false
        }

        XCTAssertEqual(fullRebaselineArguments, [true, false])
        XCTAssertTrue(coordinator.pendingFailedStreams.isEmpty)
        XCTAssertEqual(coordinator.foregroundRebaselineAttemptCount, 1)
    }

    func testGlobalFailureDoesNotMarkActivationCompleteAndUsesFullRebaselineOnRetry() async throws {
        var fullRebaselineArguments: [Bool] = []
        var callCount = 0
        let coordinator = ForegroundHealthRebaselineCoordinator(
            retryDelayNanoseconds: { _ in 1_000_000 },
            operation: { requiresFullRebaseline, _ in
                callCount += 1
                fullRebaselineArguments.append(requiresFullRebaseline)
                if callCount == 1 { throw TestFailure.injected }
                return Self.successfulResult
            }
        )

        await coordinator.activate()
        try await waitUntil {
            if case .completed = coordinator.state { return true }
            return false
        }

        XCTAssertEqual(fullRebaselineArguments, [true, true])
        XCTAssertEqual(coordinator.foregroundRebaselineAttemptCount, 2)
    }

    func testReactivationCancelsPendingRetryAndStartsImmediately() async throws {
        var calls = 0
        var fullRebaselineArguments: [Bool] = []
        let coordinator = ForegroundHealthRebaselineCoordinator(
            retryDelayNanoseconds: { _ in 60_000_000_000 },
            operation: { requiresFullRebaseline, _ in
                calls += 1
                fullRebaselineArguments.append(requiresFullRebaseline)
                if calls == 1 { throw TestFailure.injected }
                return Self.successfulResult
            }
        )

        await coordinator.activate()
        XCTAssertEqual(calls, 1)
        if case .failed(generation: 1, diagnostic: _) = coordinator.state {
            // Expected: the first activation failed and has a delayed retry queued.
        } else {
            XCTFail("Expected the first activation to fail before deactivation")
        }

        coordinator.deactivate()
        coordinator.prepareActivation()
        await coordinator.activate()

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(fullRebaselineArguments, [true, true])
        XCTAssertEqual(coordinator.state, .completed(generation: 2))
    }

    func testNewActivationDoesNotInheritPreviousGenerationBackoff() async throws {
        var retryAttempts: [Int] = []
        var calls = 0
        let coordinator = ForegroundHealthRebaselineCoordinator(
            retryDelayNanoseconds: { attempt in
                retryAttempts.append(attempt)
                return 60_000_000_000
            },
            operation: { _, _ in
                calls += 1
                return HealthSyncResult(
                    completedStreams: [],
                    failedStreams: [.heartRate: Self.failure(.heartRate)]
                )
            }
        )

        await coordinator.activate()
        coordinator.deactivate()
        coordinator.prepareActivation()
        await coordinator.activate()

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(retryAttempts, [1, 1])
        XCTAssertEqual(coordinator.state, .partiallyCompleted(
            generation: 2,
            failedStreams: [.heartRate]
        ))
    }

    func testBackgroundToForegroundDuringRetryDoesNotBlockNewGeneration() async throws {
        var generations: [Bool] = []
        var calls = 0
        let coordinator = ForegroundHealthRebaselineCoordinator(
            retryDelayNanoseconds: { _ in 60_000_000_000 },
            operation: { fullRebaseline, _ in
                calls += 1
                generations.append(fullRebaseline)
                if calls == 1 {
                    return HealthSyncResult(
                        completedStreams: [],
                        failedStreams: [.heartRate: Self.failure(.heartRate)]
                    )
                }
                return Self.successfulResult
            }
        )

        await coordinator.activate()
        coordinator.deactivate()
        await coordinator.activate()

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(generations, [true, true])
        XCTAssertEqual(coordinator.state, .completed(generation: 2))
    }

    func testSupersededRunIsNotMarkedCompleteAndRetriesTheActivation() async throws {
        var fullRebaselineArguments: [Bool] = []
        var callCount = 0
        let coordinator = ForegroundHealthRebaselineCoordinator(
            retryDelayNanoseconds: { _ in 1_000_000 },
            operation: { requiresFullRebaseline, _ in
                callCount += 1
                fullRebaselineArguments.append(requiresFullRebaseline)
                if callCount == 1 { throw HealthSyncSupersededError() }
                return Self.successfulResult
            }
        )

        await coordinator.activate()
        try await waitUntil {
            if case .completed = coordinator.state { return true }
            return false
        }

        XCTAssertEqual(fullRebaselineArguments, [true, true])
        XCTAssertEqual(coordinator.foregroundRebaselineAttemptCount, 2)
    }

    func testNewActivationQueuesBehindCurrentPreparation() async throws {
        var calls = 0
        var releaseFirst: CheckedContinuation<HealthSyncResult, Error>?
        let coordinator = ForegroundHealthRebaselineCoordinator(
            retryDelayNanoseconds: { _ in 0 },
            operation: { _, _ in
                calls += 1
                if calls == 1 {
                    return try await withCheckedThrowingContinuation { continuation in
                        releaseFirst = continuation
                    }
                }
                return Self.successfulResult
            }
        )

        let firstActivation = Task { @MainActor in await coordinator.activate() }
        try await waitUntil { calls == 1 }
        coordinator.deactivate()
        let nextActivation = Task { @MainActor in await coordinator.activate() }
        await Task.yield()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(coordinator.state, .queued(generation: 2))

        releaseFirst?.resume(returning: Self.successfulResult)
        await firstActivation.value
        await nextActivation.value
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(coordinator.state, .completed(generation: 2))
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw TestFailure.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static var successfulResult: HealthSyncResult {
        HealthSyncResult(completedStreams: HealthKitSyncCoordinator.observedStreams, failedStreams: [:])
    }

    private static func failure(_ metric: HealthMetricID) -> HealthSyncFailure {
        HealthSyncFailure(
            stream: metric,
            requestID: UUID(),
            descriptor: SharedErrorDescriptor(
                code: .healthKitUnavailable,
                userMessage: "HealthKit unavailable",
                subsystem: .healthKit,
                reason: .healthKitUnavailable
            )
        )
    }

    private enum TestFailure: Error {
        case injected
        case timedOut
    }
}
