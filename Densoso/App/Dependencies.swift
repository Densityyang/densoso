import DensosoDomain
import Foundation
import SwiftUI
import SwiftData
import Observation

enum HealthContextExportGateError: Error {
    case snapshotRebuildInProgress
}

/// Prevents cloud-facing Agent reads from observing cached HealthKit values
/// while a foreground snapshot purge is running or has failed.
@MainActor
final class HealthContextExportGate {
    private var generation: UInt64 = 0
    private(set) var isOpen: Bool

    init(initiallyOpen: Bool = false) {
        isOpen = initiallyOpen
    }

    func closeForSnapshotRebuild() -> UInt64 {
        generation &+= 1
        isOpen = false
        return generation
    }

    func openAfterSuccessfulPurge(generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration else { return }
        isOpen = true
    }

    func withAllowedExport<Value: Sendable>(
        _ export: @Sendable () async throws -> Value
    ) async throws -> Value {
        guard isOpen else { throw HealthContextExportGateError.snapshotRebuildInProgress }
        let expectedGeneration = generation
        let value = try await export()
        guard isOpen, generation == expectedGeneration else {
            throw HealthContextExportGateError.snapshotRebuildInProgress
        }
        return value
    }
}

/// 全局依赖容器 —— 持有所有 Service 单例，通过 .environment() 注入
@MainActor
@Observable
final class Dependencies {
    let modelContainer: ModelContainer
    var foodDatabase: FoodDatabase?
    let speechService: SpeechService
    let localIntelligence: LocalIntelligenceService
    let intelligencePreferences: IntelligencePreferences
    let providerConfiguration: ProviderConfigurationPreferences
    let providerRegistry: ProviderRegistry
    let providerLogBuffer: ProviderLogBuffer
    let healthKitService: HealthKitService
    let healthKitSyncCoordinator: HealthKitSyncCoordinator
    let healthContextExportGate: HealthContextExportGate
    let healthIntelligenceService: HealthIntelligenceService
    let healthProjectionActor: HealthProjectionActor
    let dailyLoopSnapshotService: DailyLoopSnapshotService
    let briefNotificationScheduler: BriefNotificationScheduler
    let dailyLoopBackgroundScheduler: DailyLoopBackgroundScheduler
    let workoutPlanSchedulingService: WorkoutPlanSchedulingService
    let watchConnectivityCoordinator: PhoneWatchConnectivityCoordinator
    let healthSyncOutboxWorker: HealthSyncOutboxWorker
    let capabilityDiagnostics: CapabilityDiagnosticsService
    let diagnosticsExportService: DiagnosticsExportService
    let exportService: ExportService
    let toolRegistry: ToolRegistry
    let agentSession: AgentSession
    let persistenceWriteGate: PersistenceWriteGate
    let confirmationRepository: SwiftDataConfirmationRepository
    let confirmationCoordinator: ConfirmationCoordinator
    let mealPortionPriorRepository: SwiftDataMealPortionPriorRepository
    let agentRepository: SwiftDataAgentRepository
    let confirmedFoodHistoryRepository: SwiftDataConfirmedFoodHistoryRepository
    let providerGovernanceRepository: SwiftDataProviderGovernanceRepository
    let providerUsageLedger: ProviderUsageLedger
    let packagedFoodProvider: (any PackagedFoodProvider)?

    /// 食材库是否已初始化
    var isFoodDBReady: Bool { foodDatabase != nil }

    init(
        automaticallyLoadFoodDatabase: Bool = true,
        modelContainer: ModelContainer? = nil,
        persistenceState: PersistenceRuntimeState = .writable
    ) {
        let modelContainer = modelContainer ?? PersistenceBootstrap.make(inMemory: true).container
        self.modelContainer = modelContainer
        let confirmationRepository = SwiftDataConfirmationRepository(modelContainer: modelContainer)
        let mealPortionPriorRepository = SwiftDataMealPortionPriorRepository(modelContainer: modelContainer)
        let agentRepository = SwiftDataAgentRepository(modelContainer: modelContainer)
        let confirmedFoodHistory = SwiftDataConfirmedFoodHistoryRepository(modelContainer: modelContainer)
        let governanceRepository = SwiftDataProviderGovernanceRepository(modelContainer: modelContainer)
        let writeGate = PersistenceWriteGate(state: persistenceState)
        let healthKitService = HealthKitService()
        let healthKitSyncCoordinator = HealthKitSyncCoordinator(
            healthStore: healthKitService.client,
            observer: healthKitService.client
        )
        let hasCachedHealthKitData = Self.hasPersistedHealthKitData(in: modelContainer.mainContext)
        let healthContextExportGate = HealthContextExportGate(
            initiallyOpen: !healthKitService.hasRequestedAuthorization && !hasCachedHealthKitData
        )
        self.healthContextExportGate = healthContextExportGate
        let briefCacheGenerationFence = HealthBriefCacheGenerationFence()
        let healthProjectionActor = HealthProjectionActor(
            modelContainer: modelContainer,
            briefCacheGenerationFence: briefCacheGenerationFence
        )
        self.healthProjectionActor = healthProjectionActor
        let healthIntelligenceService = HealthIntelligenceService(
            projectionActor: healthProjectionActor,
            briefCacheGenerationFence: briefCacheGenerationFence
        )
        self.healthIntelligenceService = healthIntelligenceService
        healthKitSyncCoordinator.onHealthCachePurgeWillBegin = {
            let generation = healthContextExportGate.closeForSnapshotRebuild()
            healthIntelligenceService.invalidateBriefsForHealthSnapshotRebuild()
            return generation
        }
        healthKitSyncCoordinator.onHealthCachePurgeDidSucceed = { generation in
            healthContextExportGate.openAfterSuccessfulPurge(generation: generation)
            if healthContextExportGate.isOpen {
                healthIntelligenceService.allowBriefRefreshAfterSuccessfulHealthSnapshotPurge()
            }
        }
        self.briefNotificationScheduler = BriefNotificationScheduler()
        let workoutPlanSchedulingService = WorkoutPlanSchedulingService(modelContainer: modelContainer)
        self.workoutPlanSchedulingService = workoutPlanSchedulingService
        let healthSyncOutboxWorker = HealthSyncOutboxWorker(
            healthStore: healthKitService.client,
            modelContainer: modelContainer
        )
        let confirmationCoordinator = ConfirmationCoordinator(
            repository: confirmationRepository,
            writeGate: writeGate,
            healthSyncOutbox: healthSyncOutboxWorker
        )
        self.localIntelligence = LocalIntelligenceService()
        let intelligencePreferences = IntelligencePreferences()
        let providerConfiguration = ProviderConfigurationPreferences()
        let providerLogBuffer = ProviderLogBuffer()
        let providerRegistry = ProviderRegistry(
            configuration: providerConfiguration,
            logSink: providerLogBuffer
        )
        let packagedFoodProvider: (any PackagedFoodProvider)?
        if let openFoodFacts = try? OpenFoodFactsPackagedFoodProvider(
            userAgent: "densoso/1.0 (iOS; meal barcode lookup)"
        ) {
            packagedFoodProvider = CachedPackagedFoodProvider(upstream: openFoodFacts)
        } else {
            packagedFoodProvider = nil
        }
        let toolRegistry = ToolRegistry(
            todayHealthStateProvider: { date in
                try await healthContextExportGate.withAllowedExport {
                    try await healthProjectionActor.todayHealthState(asOf: date)
                }
            },
            healthHistoryProvider: { start, end in
                try await healthContextExportGate.withAllowedExport {
                    try await healthProjectionActor.healthHistory(from: start, through: end)
                }
            },
            goalProfileProvider: { date in
                try await healthContextExportGate.withAllowedExport {
                    try await healthProjectionActor.goalProfile(asOf: date)
                }
            },
            mealPortionPriorRepository: mealPortionPriorRepository
        )
        self.intelligencePreferences = intelligencePreferences
        self.providerConfiguration = providerConfiguration
        self.providerRegistry = providerRegistry
        self.healthKitService = healthKitService
        self.healthKitSyncCoordinator = healthKitSyncCoordinator
        self.healthSyncOutboxWorker = healthSyncOutboxWorker
        self.capabilityDiagnostics = CapabilityDiagnosticsService()
        self.diagnosticsExportService = DiagnosticsExportService(providerLogs: providerLogBuffer)
        self.exportService = ExportService()
        self.providerLogBuffer = providerLogBuffer
        self.toolRegistry = toolRegistry
        self.persistenceWriteGate = writeGate
        self.confirmationRepository = confirmationRepository
        self.confirmationCoordinator = confirmationCoordinator
        self.mealPortionPriorRepository = mealPortionPriorRepository
        self.agentRepository = agentRepository
        self.confirmedFoodHistoryRepository = confirmedFoodHistory
        self.providerGovernanceRepository = governanceRepository
        let usageLedger = ProviderUsageLedger(repository: governanceRepository)
        self.providerUsageLedger = usageLedger
        self.packagedFoodProvider = packagedFoodProvider
        self.speechService = SpeechService(
            cloudProvider: ConfiguredQwenASRProvider(logSink: providerLogBuffer),
            governanceRepository: governanceRepository,
            usageLedger: usageLedger,
            providerConfiguration: providerConfiguration,
            cloudFallbackModeIsAllowed: { intelligencePreferences.mode != .localOnly }
        )

        let agentSession = AgentSession(
            providerSelector: providerRegistry,
            intelligencePreferences: intelligencePreferences,
            providerConfiguration: providerConfiguration,
            governanceRepository: governanceRepository,
            usageLedger: usageLedger,
            registry: toolRegistry,
            confirmationCoordinator: confirmationCoordinator,
            readRepository: agentRepository,
            conversationRepository: agentRepository,
            confirmedFoodHistory: confirmedFoodHistory,
            healthNarrativeContextProvider: {
                try await healthContextExportGate.withAllowedExport {
                    try await healthProjectionActor.healthNarrativeContext()
                }
            },
            confirmedWorkoutPlanHandler: { actionID in
                try await workoutPlanSchedulingService.scheduleConfirmedPlan(actionID: actionID)
            }
        )
        self.agentSession = agentSession
        self.dailyLoopSnapshotService = DailyLoopSnapshotService(
            healthProjectionActor: healthProjectionActor,
            healthIntelligenceService: healthIntelligenceService,
            agentSession: agentSession
        )
        let watchConnectivityCoordinator = PhoneWatchConnectivityCoordinator(
            modelContainer: modelContainer,
            agentSession: agentSession,
            healthIntelligenceService: healthIntelligenceService,
            workoutPlanSchedulingService: workoutPlanSchedulingService
        )
        self.watchConnectivityCoordinator = watchConnectivityCoordinator
        healthKitSyncCoordinator.onObserverSyncCompleted = { metric, scanGeneration in
            guard healthKitSyncCoordinator.isCurrentScanGeneration(scanGeneration, for: metric) else { return }
            _ = try? await healthIntelligenceService.refresh()
            guard healthKitSyncCoordinator.isCurrentScanGeneration(scanGeneration, for: metric) else { return }
            watchConnectivityCoordinator.refreshApplicationContext()
        }
        self.dailyLoopBackgroundScheduler = DailyLoopBackgroundScheduler(
            modelContainer: modelContainer,
            healthSyncCoordinator: healthKitSyncCoordinator,
            historicalMetricsRecomputer: HistoricalMetricsRecomputeService(modelContainer: modelContainer),
            healthIntelligenceService: healthIntelligenceService,
            dailyLoopSnapshotService: dailyLoopSnapshotService,
            notificationScheduler: briefNotificationScheduler,
            watchConnectivityCoordinator: watchConnectivityCoordinator,
            isHealthAuthorized: { healthKitService.hasRequestedAuthorization }
        )

        // 尝试加载食材库
        if automaticallyLoadFoodDatabase {
            Task { await setupFoodDB() }
        }
    }

    /// A never-connected installation may export locally entered health context.
    /// Restored or otherwise persisted HealthKit markers keep the gate closed until
    /// the bounded cache purge establishes current read scope.
    private static func hasPersistedHealthKitData(in context: ModelContext) -> Bool {
        do {
            let cursors = try context.fetch(FetchDescriptor<HealthKitImportCursor>())
            if !cursors.isEmpty { return true }
            let sampleIndexes = try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>())
            if !sampleIndexes.isEmpty { return true }
            let healthKitWeightPredicate = #Predicate<WeightRecord> { $0.source == "healthKit" }
            let healthKitWeights = try context.fetch(
                FetchDescriptor<WeightRecord>(predicate: healthKitWeightPredicate)
            )
            if !healthKitWeights.isEmpty { return true }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            for record in try context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()) {
                let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
                if snapshot.healthReadStates?.isEmpty == false
                    || snapshot.healthKitSamples?.isEmpty == false
                    || snapshot.healthKitSampleSummary.map({
                        !$0.metrics.isEmpty || $0.sleep != nil || !$0.workoutEffort.isEmpty
                    }) == true {
                    return true
                }
            }
            return false
        } catch {
            // An unreadable cache may contain HealthKit data, so keep exports closed.
            return true
        }
    }

    func restorePersistenceState() async {
        if persistenceWriteGate.state.allowsWrites {
            try? await confirmationCoordinator.recoverInterruptedCommits()
        }
        try? await agentSession.restore()
        await speechService.cleanupStaleTemporaryAudio()
    }

    /// 加载食材库（优先 SQLite，fallback 种子 JSON）
    func setupFoodDB() async {
        do {
            self.foodDatabase = try FoodDatabase()
        } catch {
            // 种子数据作为 fallback
            if let seedURL = Bundle.main.url(forResource: "seed_foods", withExtension: "json"),
               let seedData = try? Data(contentsOf: seedURL),
               let seedDB = try? FoodDatabase(seedJSON: seedData) {
                self.foodDatabase = seedDB
            }
        }
        // 注入到 AgentSession
        agentSession.foodDatabase = foodDatabase
    }

    func makeMealCaptureService() -> MealCaptureApplicationService {
        let mode = intelligencePreferences.mode
        let localOnly = mode == .localOnly
        let explicitlySelectedQwen = mode == .cloudQwen
        let visionProvider: (any MealVisionProviding)? = explicitlySelectedQwen
            ? ConfiguredQwenMealVisionProvider(logSink: providerLogBuffer)
            : nil
        return MealCaptureApplicationService(
            foodDatabase: foodDatabase,
            packagedFoodProvider: localOnly ? nil : packagedFoodProvider,
            allowsRemotePackagedFoodLookup: !localOnly,
            confirmedFoodHistory: confirmedFoodHistoryRepository,
            visionProvider: visionProvider,
            allowsQwenMealVision: explicitlySelectedQwen,
            governanceRepository: providerGovernanceRepository,
            providerConfiguration: providerConfiguration,
            usageLedger: providerUsageLedger,
            confirmationCoordinator: confirmationCoordinator
        )
    }
}
