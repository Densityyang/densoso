import SwiftUI
import SwiftData

@main
struct DensosoApp: App {
    @State private var dependencies: Dependencies
    private let persistence: PersistenceBootstrap
    private let launchConfiguration: AppLaunchConfiguration

    init() {
        let launchConfiguration = AppLaunchConfiguration.current
        let persistence = PersistenceBootstrap.make(inMemory: launchConfiguration.isUITesting)
        self.launchConfiguration = launchConfiguration
        self.persistence = persistence
        self._dependencies = State(
            initialValue: Dependencies(
                automaticallyLoadFoodDatabase: !launchConfiguration.isUITesting,
                modelContainer: persistence.container,
                persistenceState: persistence.state
            )
        )
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
    @State private var healthKitWorkoutImporter = HealthKitWorkoutImporter()
    @State private var workoutRouteImporter = WorkoutRouteImporter()

    var body: some View {
        ContentView()
            .task {
                await dependencies.setupFoodDB()
                await dependencies.restorePersistenceState()
                if launchConfiguration.isUITesting {
                    prepareUITestState()
                    return
                }
                appState.pendingWorkoutPlan = AppIntentInbox.consumeWorkoutPlan()
                appState.pendingMealText = AppIntentInbox.consumeMealText()
                checkOnboarding()
                if dependencies.persistenceWriteGate.state.allowsWrites {
                    healthKitWorkoutImporter.importChanges(in: modelContext)
                    workoutRouteImporter.importPendingRoutes(in: modelContext)
                }
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
