import SwiftUI
import SwiftData
import Observation

/// 全局依赖容器 —— 持有所有 Service 单例，通过 .environment() 注入
@MainActor
@Observable
final class Dependencies {
    var foodDatabase: FoodDatabase?
    let deepSeekClient: DeepSeekClient
    let speechService: SpeechService
    let localIntelligence: LocalIntelligenceService
    let intelligencePreferences: IntelligencePreferences
    let healthKitService: HealthKitService
    let exportService: ExportService
    let toolRegistry: ToolRegistry
    let agentSession: AgentSession

    /// 食材库是否已初始化
    var isFoodDBReady: Bool { foodDatabase != nil }

    init() {
        self.deepSeekClient = DeepSeekClient()
        self.speechService = SpeechService()
        self.localIntelligence = LocalIntelligenceService()
        self.intelligencePreferences = IntelligencePreferences()
        self.healthKitService = HealthKitService()
        self.exportService = ExportService()
        self.toolRegistry = ToolRegistry()

        self.agentSession = AgentSession(
            client: deepSeekClient,
            registry: toolRegistry
        )

        // 尝试加载食材库
        Task { await setupFoodDB() }
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
        toolRegistry.foodDatabase = foodDatabase
    }
}
