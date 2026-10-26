import SwiftUI
import SwiftData

@main
struct DensosoApp: App {
    @State private var dependencies: Dependencies
    private let persistence: PersistenceBootstrap
    private let launchConfiguration: AppLaunchConfiguration

    init() {
        PerformanceSignposts.event("App.LaunchStart")
        let launchConfiguration = AppLaunchConfiguration.current
        let persistence = PersistenceBootstrap.make(inMemory: launchConfiguration.isUITesting)
        let dependencies = Dependencies(
            automaticallyLoadFoodDatabase: !launchConfiguration.isUITesting,
            modelContainer: persistence.container,
            persistenceState: persistence.state
        )
        self.launchConfiguration = launchConfiguration
        self.persistence = persistence
        self._dependencies = State(initialValue: dependencies)
        if !launchConfiguration.isUITesting {
            dependencies.dailyLoopBackgroundScheduler.register()
        }
        AppState.shared.startupWarning = persistence.warning
    }

    var body: some Scene {
        WindowGroup {
            AppRoot(launchConfiguration: launchConfiguration)
                .modelContainer(persistence.container)
                .environment(dependencies)
                .environment(AppState.shared)
        }
    }
}

struct AppRoot: View {
    let launchConfiguration: AppLaunchConfiguration

    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(Dependencies.self) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasCompletedInitialDailyBriefRefresh = false
    @State private var isRefreshingStaleDailyBrief = false
    @State private var lastSuccessfulHealthRefreshDay: Date?
    @State private var isRebaseliningHealthForForeground = false
    @State private var isRunningForegroundHealthRebaselineTask = false
    @State private var isForegroundHealthRebaselineQueued = false
    @State private var hasRebaselinedHealthForForeground = false
    @State private var preparedHealthSnapshotRebuild: HealthKitSnapshotRebuildPreparation?

    @ViewBuilder
    var body: some View {
        if dependencies.persistenceWriteGate.state.allowsWrites {
            ContentView()
                .onAppear {
                    prepareHealthRebaselineForCurrentForegroundActivation()
                }
                .task {
                    await dependencies.setupFoodDB()
                    await dependencies.restorePersistenceState()
                    if launchConfiguration.isUITesting {
                        prepareUITestState()
                        let testRefreshDate = Date()
                        do {
                            _ = try await dependencies.healthIntelligenceService.refresh(asOf: testRefreshDate)
                            lastSuccessfulHealthRefreshDay = Calendar.autoupdatingCurrent.startOfDay(for: testRefreshDate)
                        } catch {
                            // Keep the UI-test seed; refresh policy is not exercised in this launch mode.
                        }
                        hasCompletedInitialDailyBriefRefresh = true
                        return
                    }
                    dependencies.watchConnectivityCoordinator.activate()
                    if dependencies.healthKitService.hasRequestedAuthorization {
                        await rebaselineHealthForCurrentForegroundActivation()
                        let healthRepository = HealthRepository(modelContext: modelContext)
                        try? await dependencies.healthKitSyncCoordinator.startBackgroundObservers(using: healthRepository)
                    } else {
                        prepareHealthRebaselineForCurrentForegroundActivation()
                    }
                    dependencies.dailyLoopBackgroundScheduler.scheduleNextRefresh()
                    await dependencies.healthSyncOutboxWorker.processPending(in: modelContext)
                    await dependencies.healthIntelligenceService.loadCachedBriefs()
                    let initialRefreshDate = Date()
                    do {
                        _ = try await dependencies.healthIntelligenceService.refresh(asOf: initialRefreshDate)
                        lastSuccessfulHealthRefreshDay = Calendar.autoupdatingCurrent.startOfDay(for: initialRefreshDate)
                    } catch {
                        // A stale cache can be retried when initial setup completes or on later activation.
                    }
                    let dailyLoopSnapshot = try? await dependencies.dailyLoopSnapshotService.snapshot()
                    await dependencies.briefNotificationScheduler.restoreSchedules(snapshot: dailyLoopSnapshot)
                    dependencies.watchConnectivityCoordinator.refreshApplicationContext()
                    AppIntentInbox.receivePendingDrafts()
                    if let pendingSystemIntent = AppIntentInbox.consumeDestination() {
                        appState.pendingSystemIntent = pendingSystemIntent
                    }
                    checkOnboarding()
                    hasCompletedInitialDailyBriefRefresh = true
                    await refreshStaleDailyBriefAfterActivation()
                }
                .onChange(of: dependencies.healthIntelligenceService.dailyBrief) { _, _ in
                    Task {
                        await refreshNotificationSnapshot()
                        dependencies.watchConnectivityCoordinator.refreshApplicationContext()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        dependencies.dailyLoopBackgroundScheduler.scheduleNextRefresh()
                        prepareHealthRebaselineForCurrentForegroundActivation()
                        Task {
                            await rebaselineHealthForCurrentForegroundActivation()
                            AppIntentInbox.receivePendingDrafts(receiveWorkoutPlan: false)
                            await refreshStaleDailyBriefAfterActivation()
                        }
                    } else {
                        hasRebaselinedHealthForForeground = false
                    }
                }
        } else {
            PersistenceRecoveryView(
                state: dependencies.persistenceWriteGate.state,
                warning: appState.startupWarning
            )
            .task {
                await dependencies.speechService.cleanupStaleTemporaryAudio()
            }
        }
    }

    private func refreshNotificationSnapshot() async {
        let snapshot = try? await dependencies.dailyLoopSnapshotService.snapshot()
        await dependencies.briefNotificationScheduler.updateSnapshot(snapshot)
    }

    @MainActor
    private func prepareHealthRebaselineForCurrentForegroundActivation() {
        guard !launchConfiguration.isUITesting else { return }
        guard dependencies.healthKitService.hasRequestedAuthorization else {
            // A restored snapshot can contain HealthKit markers even when its
            // connection preference was intentionally not restored. Purge the
            // bounded cache locally without issuing HealthKit queries.
            guard !dependencies.healthContextExportGate.isOpen else { return }
            let repository = HealthRepository(modelContext: modelContext)
            _ = try? dependencies.healthKitSyncCoordinator.prepareForegroundSnapshotRebuild(using: repository)
            return
        }

        if isRunningForegroundHealthRebaselineTask {
            _ = dependencies.healthContextExportGate.closeForSnapshotRebuild()
            dependencies.healthIntelligenceService.invalidateBriefsForHealthSnapshotRebuild()
            isForegroundHealthRebaselineQueued = true
            preparedHealthSnapshotRebuild = nil
            return
        }
        guard !hasRebaselinedHealthForForeground,
              !isRebaseliningHealthForForeground else { return }

        isRebaseliningHealthForForeground = true
        let repository = HealthRepository(modelContext: modelContext)
        preparedHealthSnapshotRebuild = try? dependencies.healthKitSyncCoordinator
            .prepareForegroundSnapshotRebuild(using: repository)
    }

    @MainActor
    private func rebaselineHealthForCurrentForegroundActivation() async {
        guard !launchConfiguration.isUITesting,
              dependencies.healthKitService.hasRequestedAuthorization,
              !hasRebaselinedHealthForForeground,
              !isRunningForegroundHealthRebaselineTask else { return }
        if preparedHealthSnapshotRebuild == nil {
            let repository = HealthRepository(modelContext: modelContext)
            preparedHealthSnapshotRebuild = try? dependencies.healthKitSyncCoordinator
                .prepareForegroundSnapshotRebuild(using: repository)
        }
        isRunningForegroundHealthRebaselineTask = true
        isRebaseliningHealthForForeground = true
        defer {
            isRebaseliningHealthForForeground = false
            isRunningForegroundHealthRebaselineTask = false
        }

        let repository = HealthRepository(modelContext: modelContext)
        let rebuild = preparedHealthSnapshotRebuild
        _ = try? await dependencies.healthKitSyncCoordinator.syncAvailableData(
            using: repository,
            forceRebaseline: true,
            now: rebuild?.through ?? Date(),
            preparedSnapshotRebuild: rebuild
        )
        preparedHealthSnapshotRebuild = nil
        let shouldRunQueuedRebaseline = isForegroundHealthRebaselineQueued
        isForegroundHealthRebaselineQueued = false
        hasRebaselinedHealthForForeground = !shouldRunQueuedRebaseline
        if shouldRunQueuedRebaseline {
            Task { @MainActor in
                self.prepareHealthRebaselineForCurrentForegroundActivation()
                await self.rebaselineHealthForCurrentForegroundActivation()
            }
        }
    }

    private func refreshStaleDailyBriefAfterActivation() async {
        guard !launchConfiguration.isUITesting else { return }
        let now = Date()
        let healthIntelligenceService = dependencies.healthIntelligenceService
        guard !isRefreshingStaleDailyBrief,
              DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
                initialRefreshCompleted: hasCompletedInitialDailyBriefRefresh,
                cachedBriefDayStart: healthIntelligenceService.dailyBrief?.dayStart,
                lastSuccessfulRefreshDay: lastSuccessfulHealthRefreshDay,
                asOf: now,
                calendar: .autoupdatingCurrent
              ) else { return }

        isRefreshingStaleDailyBrief = true
        defer { isRefreshingStaleDailyBrief = false }
        do {
            _ = try await healthIntelligenceService.refresh(asOf: now)
            lastSuccessfulHealthRefreshDay = Calendar.autoupdatingCurrent.startOfDay(for: now)
            dependencies.watchConnectivityCoordinator.refreshApplicationContext()
        } catch {
            // Keep the last successful brief; a later foreground activation can retry.
        }
    }

    private func prepareUITestState() {
        appState.startupWarning = nil
        appState.pendingSystemIntent = nil
        appState.shouldFocusComposer = false
        appState.shouldScrollToDailyLoop = false
        appState.pendingWorkoutPlan = nil
        appState.pendingMealText = nil
        AppIntentInbox.clearDestination()
        AppIntentInbox.clearWorkoutPlan()
        AppIntentInbox.clearQueuedWorkoutPlans()
        AppIntentInbox.clearMealText()

        guard launchConfiguration.usesSeededProfile else {
            appState.isOnboarded = false
            appState.userProfile = nil
            return
        }

        let descriptor = FetchDescriptor<UserProfile>()
        let profile: UserProfile
        if let existing = try? modelContext.fetch(descriptor).first {
            profile = existing
        } else {
            profile = UserProfile(
                name: "Gate 01 Fixture",
                biologicalSex: "female",
                dateOfBirth: Date(timeIntervalSince1970: 315_532_800),
                heightCm: 168,
                weightKg: 62,
                activityLevel: "moderate",
                dailyDeficitTarget: 400
            )
            modelContext.insert(profile)
        }
        if let revisionCount = try? modelContext.fetchCount(FetchDescriptor<ProfileRevisionRecord>()),
           revisionCount == 0,
           let dateOfBirth = profile.dateOfBirth {
            let now = Date()
            modelContext.insert(
                ProfileRevisionRecord(
                    profileKey: profile.profileKey,
                    effectiveFrom: now,
                    dateOfBirth: dateOfBirth,
                    biologicalSex: profile.biologicalSex,
                    heightCm: profile.heightCm,
                    weightKg: profile.weightKg,
                    activityLevel: profile.activityLevel,
                    source: "onboarding",
                    createdAt: now
                )
            )
        }
        if let weightCount = try? modelContext.fetchCount(FetchDescriptor<WeightRecord>()),
           weightCount == 0 {
            let now = Date()
            modelContext.insert(
                WeightRecord(
                    sourceActionKey: "gate01-fixture-weight",
                    measuredAt: now,
                    kilograms: profile.weightKg,
                    source: "manual",
                    algorithmVersion: "weight-v2",
                    confidence: 0.9
                )
            )
        }
        try? modelContext.save()
        appState.isOnboarded = true
        appState.userProfile = profile
    }

    private func checkOnboarding() {
        let descriptor = FetchDescriptor<UserProfile>()
        if let profile = try? modelContext.fetch(descriptor).first {
            appState.isOnboarded = true
            appState.userProfile = profile
        } else {
            appState.isOnboarded = false
        }
    }
}

private struct PersistenceRecoveryView: View {
    let state: PersistenceRuntimeState
    let warning: String?

    var body: some View {
        OrbitPage {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(OrbitPalette.coral)

                OrbitScreenHeader(
                    eyebrow: "Read-only recovery",
                    title: "本地数据已进入只读保护。",
                    subtitle: "迁移没有完成，因此当前不会开放记录、导入、确认或设置写入。"
                )

                if let warning {
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("诊断编号", value: state.diagnosticID ?? "unknown")
                    .font(.footnote.monospaced())

                Label(
                    "原用户 store 与迁移前备份保持独立；请保留此编号用于恢复诊断。",
                    systemImage: "lock.shield"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}
