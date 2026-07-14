import SwiftUI
import SwiftData

@main
struct DensosoApp: App {
    @State private var dependencies = Dependencies()

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .modelContainer(for: [
                    UserProfile.self,
                    MealRecord.self,
                    DishEntry.self,
                    WorkoutRecord.self,
                    DailyMetrics.self,
                    WeeklyReport.self,
                    ScheduleEvent.self
                ])
                .environment(dependencies)
                .environment(AppState.shared)
        }
    }
}

struct AppRoot: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(Dependencies.self) private var dependencies

    var body: some View {
        ContentView()
            .task {
                await dependencies.setupFoodDB()
                checkOnboarding()
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
