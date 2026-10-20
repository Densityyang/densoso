import BackgroundTasks
import Foundation
import Observation
import SwiftData
import DensosoDomain

struct HistoricalMetricsRecomputeResult: Equatable, Sendable {
    let processedCount: Int
    let hasMoreEligibleWork: Bool
    let stoppedEarly: Bool
}

@MainActor
protocol HistoricalMetricsRecomputing {
    func recomputePendingMetrics(
        now: Date,
        batchSize: Int,
        shouldStop: @MainActor () -> Bool
    ) async throws -> HistoricalMetricsRecomputeResult
}

/// Schedules opportunistic local convergence of HealthKit projections and the daily loop.
/// HealthKit observer delivery remains the primary change signal; this refresh is a retry path.
@MainActor
@Observable
final class DailyLoopBackgroundScheduler {
    static let taskIdentifier = "com.densoso.densoso.daily-loop.refresh"
    private static let historicalRecomputeBatchSize = 10
    private static let historicalRecomputeRetryInterval: TimeInterval = 15 * 60
    private static let projectionFailureFallback = SharedErrorDescriptor(
        code: .projectionFailed,
        userMessage: "暂时没能更新今天的状态。",
        subsystem: .projection,
        reason: .dailyMetricsProjectionFailed
    )

    private let modelContainer: ModelContainer
    private let healthSyncCoordinator: HealthKitSyncCoordinator
    private let historicalMetricsRecomputer: any HistoricalMetricsRecomputing
    private let healthIntelligenceService: HealthIntelligenceService
    private let dailyLoopSnapshotService: DailyLoopSnapshotService
    private let notificationScheduler: BriefNotificationScheduler
    private let watchConnectivityCoordinator: PhoneWatchConnectivityCoordinator
    private let isHealthAuthorized: @MainActor () -> Bool

    private(set) var isRegistered = false
    private(set) var lastError: String?
    private(set) var nextRefreshEarliestAt: Date?
    private var activeRefreshTask: Task<Void, Never>?

    init(
        modelContainer: ModelContainer,
        healthSyncCoordinator: HealthKitSyncCoordinator,
        historicalMetricsRecomputer: any HistoricalMetricsRecomputing,
        healthIntelligenceService: HealthIntelligenceService,
        dailyLoopSnapshotService: DailyLoopSnapshotService,
        notificationScheduler: BriefNotificationScheduler,
        watchConnectivityCoordinator: PhoneWatchConnectivityCoordinator,
        isHealthAuthorized: @escaping @MainActor () -> Bool
    ) {
        self.modelContainer = modelContainer
        self.healthSyncCoordinator = healthSyncCoordinator
        self.historicalMetricsRecomputer = historicalMetricsRecomputer
        self.healthIntelligenceService = healthIntelligenceService
        self.dailyLoopSnapshotService = dailyLoopSnapshotService
        self.notificationScheduler = notificationScheduler
        self.watchConnectivityCoordinator = watchConnectivityCoordinator
        self.isHealthAuthorized = isHealthAuthorized
    }

    /// Must run during application launch, before the system delivers a pending refresh.
    func register() {
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let taskBox = BackgroundRefreshTaskBox(refreshTask)
            Task { @MainActor [weak self, taskBox] in
                guard let self else {
                    taskBox.complete(success: false)
                    return
                }
                self.handle(taskBox)
            }
        }
        if !isRegistered {
            lastError = "系统未注册每日健康回顾后台任务。"
        }
    }

    /// Requests one best-effort refresh. iOS chooses the actual launch time.
    func scheduleNextRefresh(earliestBeginInterval: TimeInterval = 6 * 60 * 60) {
        guard isRegistered, isHealthAuthorized() else {
            nextRefreshEarliestAt = nil
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            return
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(max(earliestBeginInterval, 60))
        do {
            try BGTaskScheduler.shared.submit(request)
            nextRefreshEarliestAt = request.earliestBeginDate
            lastError = nil
        } catch {
            nextRefreshEarliestAt = nil
            let fallback = SharedErrorDescriptor(
                code: .projectionFailed,
                userMessage: "每日健康回顾暂时无法安排。",
                subsystem: .projection,
                reason: .unsupportedCapability,
                numericCode: (error as NSError).code
            )
            lastError = SharedErrorDescriptor.mapped(from: error, fallback: fallback).diagnosticSafeDetail
        }
    }

    private func handle(_ taskBox: BackgroundRefreshTaskBox) {
        scheduleNextRefresh()
        guard isHealthAuthorized() else {
            taskBox.complete(success: false)
            return
        }
        guard let backgroundTask = taskBox.task else {
            taskBox.complete(success: false)
            return
        }
        let refreshOperation = Task { @MainActor [weak self] in
            guard let self else {
                taskBox.complete(success: false)
                return
            }
            defer { self.activeRefreshTask = nil }

            do {
                guard !Task.isCancelled, !taskBox.isExpired else {
                    taskBox.complete(success: false)
                    return
                }
                let repository = HealthRepository(modelContext: self.modelContainer.mainContext)
                let syncResult = try await self.healthSyncCoordinator.syncAvailableData(using: repository)
                guard !Task.isCancelled, !taskBox.isExpired else {
                    taskBox.complete(success: false)
                    return
                }
                let recomputeResult = try await self.historicalMetricsRecomputer.recomputePendingMetrics(
                    now: Date(),
                    batchSize: Self.historicalRecomputeBatchSize,
                    shouldStop: { Task.isCancelled || taskBox.isExpired }
                )
                if recomputeResult.hasMoreEligibleWork {
                    self.scheduleNextRefresh(
                        earliestBeginInterval: Self.historicalRecomputeRetryInterval
                    )
                }
                guard !Task.isCancelled, !taskBox.isExpired else {
                    taskBox.complete(success: false)
                    return
                }
                _ = try await self.healthIntelligenceService.refresh()
                guard !Task.isCancelled, !taskBox.isExpired else {
                    taskBox.complete(success: false)
                    return
                }
                let snapshot = try await self.dailyLoopSnapshotService.snapshot()
                guard !Task.isCancelled, !taskBox.isExpired else {
                    taskBox.complete(success: false)
                    return
                }
                await self.notificationScheduler.updateSnapshot(snapshot)
                guard !Task.isCancelled, !taskBox.isExpired else {
                    taskBox.complete(success: false)
                    return
                }
                self.watchConnectivityCoordinator.refreshApplicationContext()
                guard !Task.isCancelled, !taskBox.isExpired else {
                    taskBox.complete(success: false)
                    return
                }
                let succeeded = !syncResult.hasFailures
                self.lastError = syncResult.failedStreams.isEmpty
                    ? nil
                    : "部分 HealthKit 数据将在后续刷新时重试。"
                taskBox.complete(success: succeeded)
            } catch {
                guard !Task.isCancelled, !taskBox.isExpired else {
                    taskBox.complete(success: false)
                    return
                }
                self.lastError = SharedErrorDescriptor.mapped(
                    from: error,
                    fallback: Self.projectionFailureFallback
                ).diagnosticSafeDetail
                taskBox.complete(success: false)
            }
        }
        activeRefreshTask = refreshOperation
        backgroundTask.expirationHandler = { [taskBox, refreshOperation] in
            taskBox.expire {
                guard taskBox.canCancelActiveRefresh else { return }
                refreshOperation.cancel()
            }
        }
    }
}

/// Carries the Objective-C BackgroundTasks handle and completion state across a launch queue hop.
final class BackgroundRefreshTaskBox: @unchecked Sendable {
    let task: BGAppRefreshTask?
    private let completion: (Bool) -> Void
    private let lock = NSLock()
    private var expired = false
    private var completed = false

    var isExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }

    var canCancelActiveRefresh: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired && !completed
    }

    init(_ task: BGAppRefreshTask) {
        self.task = task
        self.completion = { task.setTaskCompleted(success: $0) }
    }

    init(completion: @escaping (Bool) -> Void) {
        self.task = nil
        self.completion = completion
    }

    func expire(scheduleCancellation: () -> Void) {
        guard markExpired() else { return }
        scheduleCancellation()
    }

    func markExpired() -> Bool {
        lock.lock()
        guard !completed, !expired else {
            lock.unlock()
            return false
        }
        expired = true
        lock.unlock()
        return true
    }

    func complete(success: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let finalSuccess = success && !expired
        lock.unlock()
        completion(finalSuccess)
    }
}
