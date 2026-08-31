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

    @ViewBuilder
    var body: some View {
        if dependencies.persistenceWriteGate.state.allowsWrites {
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
                    healthKitWorkoutImporter.importChanges(in: modelContext)
                    workoutRouteImporter.importPendingRoutes(in: modelContext)
                }
        } else {
            PersistenceRecoveryView(
                state: dependencies.persistenceWriteGate.state,
                warning: appState.startupWarning
            )
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
