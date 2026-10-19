import BackgroundTasks
import Foundation
import Observation
import SwiftData

/// Schedules opportunistic local convergence of HealthKit projections and the daily loop.
/// HealthKit observer delivery remains the primary change signal; this refresh is a retry path.
@MainActor
@Observable
final class DailyLoopBackgroundScheduler {
    static let taskIdentifier = "com.densoso.densoso.daily-loop.refresh"

    private let modelContainer: ModelContainer
    private let healthSyncCoordinator: HealthKitSyncCoordinator
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
        healthIntelligenceService: HealthIntelligenceService,
        dailyLoopSnapshotService: DailyLoopSnapshotService,
        notificationScheduler: BriefNotificationScheduler,
        watchConnectivityCoordinator: PhoneWatchConnectivityCoordinator,
        isHealthAuthorized: @escaping @MainActor () -> Bool
    ) {
        self.modelContainer = modelContainer
        self.healthSyncCoordinator = healthSyncCoordinator
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
                    taskBox.task.setTaskCompleted(success: false)
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
            lastError = String(String(describing: error).prefix(240))
        }
    }

    private func handle(_ taskBox: BackgroundRefreshTaskBox) {
        scheduleNextRefresh()
        guard isHealthAuthorized() else {
            taskBox.task.setTaskCompleted(success: false)
            return
        }
        taskBox.task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.activeRefreshTask?.cancel()
            }
        }

        activeRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                taskBox.task.setTaskCompleted(success: false)
                return
            }
            defer { self.activeRefreshTask = nil }

            do {
                let repository = HealthRepository(modelContext: self.modelContainer.mainContext)
                let syncResult = try await self.healthSyncCoordinator.syncAvailableData(using: repository)
                guard !Task.isCancelled else {
                    taskBox.task.setTaskCompleted(success: false)
                    return
                }
                _ = try self.healthIntelligenceService.refresh()
                let snapshot = try self.dailyLoopSnapshotService.snapshot()
                await self.notificationScheduler.updateSnapshot(snapshot)
                self.watchConnectivityCoordinator.refreshApplicationContext()
                let succeeded = !syncResult.hasFailures
                self.lastError = syncResult.failedStreams.isEmpty
                    ? nil
                    : "部分 HealthKit 数据将在后续刷新时重试。"
                taskBox.task.setTaskCompleted(success: succeeded)
            } catch {
                self.lastError = String(String(describing: error).prefix(240))
                taskBox.task.setTaskCompleted(success: false)
            }
        }
    }
}

/// Carries the Objective-C BackgroundTasks handle across the launch queue hop.
private final class BackgroundRefreshTaskBox: @unchecked Sendable {
    let task: BGAppRefreshTask

    init(_ task: BGAppRefreshTask) {
        self.task = task
    }
}
