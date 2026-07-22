import SwiftUI
import SwiftData

@main
struct DensosoApp: App {
    @State private var dependencies = Dependencies()
    private let sharedModelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: DensosoSchemaV1.self)
        return try! ModelContainer(for: schema, migrationPlan: DensosoMigrationPlan.self)
    }()

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .modelContainer(sharedModelContainer)
                .environment(dependencies)
                .environment(AppState.shared)
        }
    }
}

struct AppRoot: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(Dependencies.self) private var dependencies
    @State private var healthKitWorkoutImporter = HealthKitWorkoutImporter()
    @State private var workoutRouteImporter = WorkoutRouteImporter()

    var body: some View {
        ContentView()
            .task {
                await dependencies.setupFoodDB()
                checkOnboarding()
                healthKitWorkoutImporter.importChanges(in: modelContext)
                workoutRouteImporter.importPendingRoutes(in: modelContext)
            }
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
