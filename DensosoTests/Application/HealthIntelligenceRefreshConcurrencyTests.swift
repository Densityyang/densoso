import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class HealthIntelligenceRefreshConcurrencyTests: XCTestCase {
    func testRecoveryRequiredBarrierRejectsBriefRefreshBeforePersistenceWork() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let fence = HealthBriefCacheGenerationFence()
        let actor = HealthProjectionActor(
            modelContainer: container,
            briefCacheGenerationFence: fence
        )
        let barrier = PersistenceOperationBarrier()
        barrier.requireRecovery()
        var refreshCalls = 0
        let service = HealthIntelligenceService(
            projectionActor: actor,
            briefCacheGenerationFence: fence,
            refreshOperation: { date, _ in
                refreshCalls += 1
                return Self.snapshot(fingerprint: "should-not-run", validatedAt: date)
            },
            persistenceOperationBarrier: barrier
        )

        do {
            _ = try await service.refresh()
            XCTFail("Recovery mode must reject cache writes")
        } catch {
            XCTAssertEqual(error as? PersistenceLifecycleError, .recoveryRequired)
        }
        XCTAssertEqual(refreshCalls, 0)
    }

    func testLatestRefreshRequestRunsAfterOlderRequestAndOwnsPublishedFingerprint() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let fence = HealthBriefCacheGenerationFence()
        let actor = HealthProjectionActor(
            modelContainer: container,
            briefCacheGenerationFence: fence
        )
        let barrier = PersistenceOperationBarrier()
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let secondDate = firstDate.addingTimeInterval(1)
        var startedDates: [Date] = []
        var continuations: [Date: CheckedContinuation<HealthIntelligenceRefreshSnapshot, Error>] = [:]
        let starts = AsyncCallCounter()
        let service = HealthIntelligenceService(
            projectionActor: actor,
            briefCacheGenerationFence: fence,
            refreshOperation: { date, _ in
                try await withCheckedThrowingContinuation { continuation in
                    startedDates.append(date)
                    continuations[date] = continuation
                    starts.signal()
                }
            },
            persistenceOperationBarrier: barrier
        )

        let firstRefresh = Task { @MainActor in try await service.refresh(asOf: firstDate) }
        await starts.wait(until: 1)
        let latestRefresh = Task { @MainActor in try await service.refresh(asOf: secondDate) }
        await Task.yield()
        XCTAssertEqual(startedDates, [firstDate])

        continuations.removeValue(forKey: firstDate)?.resume(returning: Self.snapshot(fingerprint: "old-source"))
        await starts.wait(until: 2)
        XCTAssertNotEqual(service.dailyBriefSourceFingerprint, "old-source")
        continuations.removeValue(forKey: secondDate)?.resume(
            returning: Self.snapshot(fingerprint: "new-source", validatedAt: secondDate)
        )
        _ = try await firstRefresh.value
        _ = try await latestRefresh.value

        XCTAssertEqual(service.dailyBriefSourceFingerprint, "new-source")
        XCTAssertEqual(service.dailyBriefValidatedAt, secondDate)
    }

    func testObserverRefreshRequestsAreDebounced() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let fence = HealthBriefCacheGenerationFence()
        let actor = HealthProjectionActor(
            modelContainer: container,
            briefCacheGenerationFence: fence
        )
        let barrier = PersistenceOperationBarrier()
        var refreshCount = 0
        let service = HealthIntelligenceService(
            projectionActor: actor,
            briefCacheGenerationFence: fence,
            refreshOperation: { date, _ in
                refreshCount += 1
                return Self.snapshot(fingerprint: "observer-\(refreshCount)", validatedAt: date)
            },
            observerRefreshDelay: { _ in },
            persistenceOperationBarrier: barrier
        )
        var completions = 0
        let completion = expectation(description: "debounced observer refresh completes")

        service.scheduleRefreshAfterHealthObserverEvent { completions += 1 }
        service.scheduleRefreshAfterHealthObserverEvent { completions += 1 }
        service.scheduleRefreshAfterHealthObserverEvent {
            completions += 1
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 5)

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(service.dailyBriefSourceFingerprint, "observer-1")
    }

    private static func snapshot(
        fingerprint: String,
        validatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> HealthIntelligenceRefreshSnapshot {
        HealthIntelligenceRefreshSnapshot(
            dailyBrief: nil,
            dailyBriefSourceFingerprint: fingerprint,
            dailyBriefValidatedAt: validatedAt,
            weeklyBrief: nil,
            updatesWeeklyBrief: false
        )
    }

}

@MainActor
private final class AsyncCallCounter {
    private(set) var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signal() {
        count += 1
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
    }

    func wait(until expectedCount: Int) async {
        guard count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            if count >= expectedCount {
                continuation.resume()
            } else {
                waiters.append((expectedCount, continuation))
            }
        }
    }
}
