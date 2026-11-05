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

enum DailyLoopBackgroundSchedulePolicy {
    static func shouldReplace(existingEarliestAt: Date?, requestedEarliestAt: Date) -> Bool {
        guard let existingEarliestAt else { return true }
        return requestedEarliestAt < existingEarliestAt
    }
}

enum DailyLoopBackgroundRefreshReason: String, Equatable, Sendable {
    case regular
    case historicalRecompute
    case healthSyncRecovery
    case projectionRecovery

    var earliestBeginInterval: TimeInterval {
        switch self {
        case .regular:
            return 6 * 60 * 60
        case .historicalRecompute, .healthSyncRecovery, .projectionRecovery:
            return 15 * 60
        }
    }
}

struct DailyLoopBackgroundTaskRequest: Equatable, Sendable {
    let identifier: String
    let earliestBeginDate: Date
    let reason: DailyLoopBackgroundRefreshReason
}

@MainActor
protocol DailyLoopBackgroundTaskScheduling {
    func submit(_ request: DailyLoopBackgroundTaskRequest) throws
    func cancel(taskRequestWithIdentifier identifier: String)
}

@MainActor
struct SystemDailyLoopBackgroundTaskScheduler: DailyLoopBackgroundTaskScheduling {
    func submit(_ request: DailyLoopBackgroundTaskRequest) throws {
        let systemRequest = BGAppRefreshTaskRequest(identifier: request.identifier)
        systemRequest.earliestBeginDate = request.earliestBeginDate
        // Submitting replaces an unexecuted request with the same identifier
        // only after success; a failed submission leaves the old request queued.
        try BGTaskScheduler.shared.submit(systemRequest)
    }

    func cancel(taskRequestWithIdentifier identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

@MainActor
final class DailyLoopBackgroundScheduleController {
    private let client: any DailyLoopBackgroundTaskScheduling
    private let defaults: UserDefaults
    private let taskIdentifier: String
    private let earliestDateKey: String
    private let reasonKey: String

    private(set) var nextRefreshEarliestAt: Date?
    private(set) var nextRefreshReason: DailyLoopBackgroundRefreshReason?

    init(
        client: any DailyLoopBackgroundTaskScheduling,
        defaults: UserDefaults,
        taskIdentifier: String,
        earliestDateKey: String,
        reasonKey: String
    ) {
        self.client = client
        self.defaults = defaults
        self.taskIdentifier = taskIdentifier
        self.earliestDateKey = earliestDateKey
        self.reasonKey = reasonKey
        nextRefreshEarliestAt = defaults.object(forKey: earliestDateKey) as? Date
        nextRefreshReason = defaults.string(forKey: reasonKey)
            .flatMap { DailyLoopBackgroundRefreshReason(rawValue: $0) }
    }

    func submit(_ request: DailyLoopBackgroundTaskRequest) throws {
        try client.submit(request)
        nextRefreshEarliestAt = request.earliestBeginDate
        nextRefreshReason = request.reason
        defaults.set(request.earliestBeginDate, forKey: earliestDateKey)
        defaults.set(request.reason.rawValue, forKey: reasonKey)
    }

    func preserveLegacyRequestReasonIfNeeded() {
        guard nextRefreshEarliestAt != nil, nextRefreshReason == nil else { return }
        nextRefreshReason = .regular
        defaults.set(DailyLoopBackgroundRefreshReason.regular.rawValue, forKey: reasonKey)
    }

    func clearPersistedSchedule() {
        nextRefreshEarliestAt = nil
        nextRefreshReason = nil
        defaults.removeObject(forKey: earliestDateKey)
        defaults.removeObject(forKey: reasonKey)
    }

    func cancelAndClear() {
        client.cancel(taskRequestWithIdentifier: taskIdentifier)
        clearPersistedSchedule()
    }
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
    private static let nextRefreshDefaultsKey = "dailyLoop.nextRefreshEarliestAt"
    private static let nextRefreshReasonDefaultsKey = "dailyLoop.nextRefreshReason"
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
    private let scheduleController: DailyLoopBackgroundScheduleController
    private let prepareLocalHealthCacheIfNeeded: @MainActor (HealthRepository) async throws -> Void

    private(set) var isRegistered = false
    private(set) var lastError: String?
    private var activeRefreshTask: Task<Void, Never>?

    var nextRefreshEarliestAt: Date? { scheduleController.nextRefreshEarliestAt }
    var nextRefreshReason: DailyLoopBackgroundRefreshReason? { scheduleController.nextRefreshReason }

    init(
        modelContainer: ModelContainer,
        healthSyncCoordinator: HealthKitSyncCoordinator,
        historicalMetricsRecomputer: any HistoricalMetricsRecomputing,
        healthIntelligenceService: HealthIntelligenceService,
        dailyLoopSnapshotService: DailyLoopSnapshotService,
        notificationScheduler: BriefNotificationScheduler,
        watchConnectivityCoordinator: PhoneWatchConnectivityCoordinator,
        isHealthAuthorized: @escaping @MainActor () -> Bool,
        backgroundTaskScheduler: any DailyLoopBackgroundTaskScheduling = SystemDailyLoopBackgroundTaskScheduler(),
        scheduleDefaults: UserDefaults = .standard,
        prepareLocalHealthCacheIfNeeded: @escaping @MainActor (HealthRepository) async throws -> Void = { _ in }
    ) {
        self.modelContainer = modelContainer
        self.healthSyncCoordinator = healthSyncCoordinator
        self.historicalMetricsRecomputer = historicalMetricsRecomputer
        self.healthIntelligenceService = healthIntelligenceService
        self.dailyLoopSnapshotService = dailyLoopSnapshotService
        self.notificationScheduler = notificationScheduler
        self.watchConnectivityCoordinator = watchConnectivityCoordinator
        self.isHealthAuthorized = isHealthAuthorized
        scheduleController = DailyLoopBackgroundScheduleController(
            client: backgroundTaskScheduler,
            defaults: scheduleDefaults,
            taskIdentifier: Self.taskIdentifier,
            earliestDateKey: Self.nextRefreshDefaultsKey,
            reasonKey: Self.nextRefreshReasonDefaultsKey
        )
        self.prepareLocalHealthCacheIfNeeded = prepareLocalHealthCacheIfNeeded
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
    @discardableResult
    func scheduleNextRefresh(reason: DailyLoopBackgroundRefreshReason = .regular) -> Bool {
        guard isRegistered else {
            scheduleController.cancelAndClear()
            return false
        }
        let requestedEarliestAt = Date().addingTimeInterval(max(reason.earliestBeginInterval, 60))
        guard DailyLoopBackgroundSchedulePolicy.shouldReplace(
            existingEarliestAt: nextRefreshEarliestAt,
            requestedEarliestAt: requestedEarliestAt
        ) else {
            // Preserve the reason paired with an earlier persisted request. If
            // upgrading from a build that stored only the date, classify that
            // legacy request as regular and persist the migrated reason.
            scheduleController.preserveLegacyRequestReasonIfNeeded()
            return true
        }

        let request = DailyLoopBackgroundTaskRequest(
            identifier: Self.taskIdentifier,
            earliestBeginDate: requestedEarliestAt,
            reason: reason
        )
        do {
            try scheduleController.submit(request)
            return true
        } catch {
            let fallback = SharedErrorDescriptor(
                code: .projectionFailed,
                userMessage: "每日健康回顾暂时无法安排。",
                subsystem: .projection,
                reason: .unsupportedCapability,
                numericCode: (error as NSError).code
            )
            lastError = SharedErrorDescriptor.mapped(from: error, fallback: fallback).diagnosticSafeDetail
            return false
        }
    }

    private func handle(_ taskBox: BackgroundRefreshTaskBox) {
        // The delivered request is no longer pending; clear its persisted time
        // before scheduling the next normal wakeup.
        clearScheduledRefresh()
        let didScheduleNextRefresh = scheduleNextRefresh()
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
                var succeeded = didScheduleNextRefresh
                if self.isHealthAuthorized() {
                    do {
                        let syncResult = try await self.healthSyncCoordinator.syncAvailableData(
                            using: repository,
                            forceRebaseline: false,
                            aggregateIncrementalLookbackDays: 3
                        )
                        guard !Task.isCancelled, !taskBox.isExpired else {
                            taskBox.complete(success: false)
                            return
                        }
                        if syncResult.hasFailures {
                            succeeded = false
                            self.lastError = "部分 HealthKit 数据将在后续刷新时重试。"
                            _ = self.scheduleNextRefresh(reason: .healthSyncRecovery)
                        }
                    } catch {
                        guard !Task.isCancelled, !taskBox.isExpired else {
                            taskBox.complete(success: false)
                            return
                        }
                        succeeded = false
                        self.lastError = SharedErrorDescriptor.mapped(
                            from: error,
                            fallback: Self.projectionFailureFallback
                        ).diagnosticSafeDetail
                        _ = self.scheduleNextRefresh(reason: .healthSyncRecovery)
                    }
                } else {
                    do {
                        try await self.prepareLocalHealthCacheIfNeeded(repository)
                        guard !Task.isCancelled, !taskBox.isExpired else {
                            taskBox.complete(success: false)
                            return
                        }
                    } catch {
                        guard !Task.isCancelled, !taskBox.isExpired else {
                            taskBox.complete(success: false)
                            return
                        }
                        succeeded = false
                        self.lastError = SharedErrorDescriptor.mapped(
                            from: error,
                            fallback: Self.projectionFailureFallback
                        ).diagnosticSafeDetail
                        _ = self.scheduleNextRefresh(reason: .healthSyncRecovery)
                    }
                }
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
                    if !self.scheduleNextRefresh(
                        reason: .historicalRecompute
                    ) { succeeded = false }
                }
                guard !Task.isCancelled, !taskBox.isExpired else {
                    taskBox.complete(success: false)
                    return
                }
                do {
                    _ = try await self.healthIntelligenceService.refresh()
                    guard !Task.isCancelled, !taskBox.isExpired else {
                        taskBox.complete(success: false)
                        return
                    }
                } catch {
                    guard !Task.isCancelled, !taskBox.isExpired else {
                        taskBox.complete(success: false)
                        return
                    }
                    succeeded = false
                    self.lastError = SharedErrorDescriptor.mapped(
                        from: error,
                        fallback: Self.projectionFailureFallback
                    ).diagnosticSafeDetail
                    _ = self.scheduleNextRefresh(reason: .projectionRecovery)
                }
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
                if succeeded { self.lastError = nil }
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
                _ = self.scheduleNextRefresh(reason: .projectionRecovery)
                taskBox.complete(success: false)
            }
        }
        activeRefreshTask = refreshOperation
        backgroundTask.expirationHandler = { [weak self, taskBox, refreshOperation] in
            let didExpire = taskBox.expire {
                guard taskBox.canCancelActiveRefresh else { return }
                refreshOperation.cancel()
            }
            guard didExpire else { return }
            Task { @MainActor [weak self] in
                _ = self?.scheduleNextRefresh(reason: .projectionRecovery)
            }
        }
    }

    private func clearScheduledRefresh() {
        scheduleController.clearPersistedSchedule()
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

    @discardableResult
    func expire(scheduleCancellation: () -> Void) -> Bool {
        guard markExpired() else { return false }
        scheduleCancellation()
        return true
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
