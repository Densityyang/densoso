import SwiftUI
import SwiftData

@main
struct DensosoApp: App {
    @State private var dependencies: Dependencies
    private let persistence: PersistenceBootstrap
    private let launchConfiguration: AppLaunchConfiguration

    init() {
        let launchConfiguration = AppLaunchConfiguration.current
        self.launchConfiguration = launchConfiguration
        self._dependencies = State(
            initialValue: Dependencies(automaticallyLoadFoodDatabase: !launchConfiguration.isUITesting)
        )
        self.persistence = PersistenceBootstrap.make(inMemory: launchConfiguration.isUITesting)
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

private struct PersistenceBootstrap {
    let container: ModelContainer
    let warning: String?

    static func make(inMemory: Bool = false) -> PersistenceBootstrap {
        let schema = Schema(versionedSchema: DensosoSchemaV2.self)
        if inMemory {
            let configuration = ModelConfiguration(
                "DensosoUITests",
                schema: schema,
                isStoredInMemoryOnly: true
            )
            do {
                return PersistenceBootstrap(
                    container: try ModelContainer(for: schema, configurations: [configuration]),
                    warning: nil
                )
            } catch {
                fatalError("Unable to create the UI test model container: \(error.localizedDescription)")
            }
        }
        do {
            return PersistenceBootstrap(
                container: try ModelContainer(for: schema, migrationPlan: DensosoMigrationPlan.self),
                warning: nil
            )
        } catch {
            // Preserve an incompatible store and keep the app launchable. The recovery
            // configuration uses a separate on-disk store; it does not delete user data.
            let recoveryConfiguration = ModelConfiguration("DensosoRecovery", schema: schema)
            do {
                return PersistenceBootstrap(
                    container: try ModelContainer(for: schema, configurations: [recoveryConfiguration]),
                    warning: "原本地数据暂时无法迁移，已启用新的本地存储。原数据未被删除。"
                )
            } catch {
                fatalError("Unable to create a SwiftData container: \(error.localizedDescription)")
            }
        }
    }
}

struct AppRoot: View {
    let launchConfiguration: AppLaunchConfiguration

    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(Dependencies.self) private var dependencies
    @State private var healthKitWorkoutImporter = HealthKitWorkoutImporter()
    @State private var workoutRouteImporter = WorkoutRouteImporter()

    var body: some View {
        ContentView()
            .task {
                await dependencies.setupFoodDB()
                if launchConfiguration.isUITesting {
                    prepareUITestState()
                    return
                }
                appState.pendingWorkoutPlan = AppIntentInbox.consumeWorkoutPlan()
                appState.pendingMealText = AppIntentInbox.consumeMealText()
                checkOnboarding()
                healthKitWorkoutImporter.importChanges(in: modelContext)
                workoutRouteImporter.importPendingRoutes(in: modelContext)
            }
    }

    private func prepareUITestState() {
        appState.startupWarning = nil
        appState.pendingWorkoutPlan = nil
        appState.pendingMealText = nil

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
            try? modelContext.save()
        }
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
