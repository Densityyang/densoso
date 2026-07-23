import SwiftUI
import SwiftData

@main
struct DensosoApp: App {
    @State private var dependencies = Dependencies()
    private let persistence = PersistenceBootstrap.make()

    init() {
        AppState.shared.startupWarning = persistence.warning
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .modelContainer(persistence.container)
                .environment(dependencies)
                .environment(AppState.shared)
        }
    }
}

private struct PersistenceBootstrap {
    let container: ModelContainer
    let warning: String?

    static func make() -> PersistenceBootstrap {
        let schema = Schema(versionedSchema: DensosoSchemaV1.self)
        do {
            return PersistenceBootstrap(
                container: try ModelContainer(for: schema, migrationPlan: DensosoMigrationPlan.self),
                warning: nil
            )
        } catch {
            // Preserve the incompatible store by opening a separately named store instead of
            // deleting user data or terminating during app launch.
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
