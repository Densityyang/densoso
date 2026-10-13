import DensosoDomain
import SwiftUI
import SwiftData
import Observation

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
    let healthKitService: HealthKitService
    let capabilityDiagnostics: CapabilityDiagnosticsService
    let workoutSessionMirroringService: WorkoutSessionMirroringService
    let exportService: ExportService
    let toolRegistry: ToolRegistry
    let agentSession: AgentSession
    let persistenceWriteGate: PersistenceWriteGate
    let confirmationRepository: SwiftDataConfirmationRepository
    let confirmationCoordinator: ConfirmationCoordinator
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
        let agentRepository = SwiftDataAgentRepository(modelContainer: modelContainer)
        let confirmedFoodHistory = SwiftDataConfirmedFoodHistoryRepository(modelContainer: modelContainer)
        let governanceRepository = SwiftDataProviderGovernanceRepository(modelContainer: modelContainer)
        let writeGate = PersistenceWriteGate(state: persistenceState)
        let confirmationCoordinator = ConfirmationCoordinator(
            repository: confirmationRepository,
            writeGate: writeGate
        )
        self.localIntelligence = LocalIntelligenceService()
        let intelligencePreferences = IntelligencePreferences()
        let providerConfiguration = ProviderConfigurationPreferences()
        let providerRegistry = ProviderRegistry(configuration: providerConfiguration)
        let packagedFoodProvider: (any PackagedFoodProvider)?
        if let openFoodFacts = try? OpenFoodFactsPackagedFoodProvider(
            userAgent: "densoso/1.0 (iOS; meal barcode lookup)"
        ) {
            packagedFoodProvider = CachedPackagedFoodProvider(upstream: openFoodFacts)
        } else {
            packagedFoodProvider = nil
        }
        let toolRegistry = ToolRegistry()
        self.intelligencePreferences = intelligencePreferences
        self.providerConfiguration = providerConfiguration
        self.providerRegistry = providerRegistry
        self.healthKitService = HealthKitService()
        self.capabilityDiagnostics = CapabilityDiagnosticsService()
        self.workoutSessionMirroringService = WorkoutSessionMirroringService()
        self.exportService = ExportService()
        self.toolRegistry = toolRegistry
        self.persistenceWriteGate = writeGate
        self.confirmationRepository = confirmationRepository
        self.confirmationCoordinator = confirmationCoordinator
        self.agentRepository = agentRepository
        self.confirmedFoodHistoryRepository = confirmedFoodHistory
        self.providerGovernanceRepository = governanceRepository
        let usageLedger = ProviderUsageLedger(repository: governanceRepository)
        self.providerUsageLedger = usageLedger
        self.packagedFoodProvider = packagedFoodProvider
        self.speechService = SpeechService(
            cloudProvider: ConfiguredQwenASRProvider(),
            governanceRepository: governanceRepository,
            usageLedger: usageLedger,
            providerConfiguration: providerConfiguration
        )

        self.agentSession = AgentSession(
            providerSelector: providerRegistry,
            intelligencePreferences: intelligencePreferences,
            providerConfiguration: providerConfiguration,
            governanceRepository: governanceRepository,
            usageLedger: usageLedger,
            registry: toolRegistry,
            confirmationCoordinator: confirmationCoordinator,
            readRepository: agentRepository,
            conversationRepository: agentRepository,
            confirmedFoodHistory: confirmedFoodHistory
        )

        // 尝试加载食材库
        if automaticallyLoadFoodDatabase {
            Task { await setupFoodDB() }
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
        return MealCaptureApplicationService(
            foodDatabase: foodDatabase,
            confirmedFoodHistory: confirmedFoodHistoryRepository,
            packagedFoodProvider: packagedFoodProvider,
            visionProvider: ConfiguredQwenMealVisionProvider(),
            governanceRepository: providerGovernanceRepository,
            providerConfiguration: providerConfiguration,
            usageLedger: providerUsageLedger,
            confirmationCoordinator: confirmationCoordinator
        )
    }
}
