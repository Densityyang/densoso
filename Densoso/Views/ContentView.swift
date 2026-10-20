import SwiftUI
import SwiftData
import DensosoDomain

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        OrbitPage {
            VStack(spacing: 0) {
                if let warning = appState.startupWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(OrbitPalette.coral)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OrbitPalette.coral.opacity(0.12))
                }

                Group {
                    if appState.isOnboarded {
                        MainTabView()
                    } else {
                        OnboardingView()
                    }
                }
            }
        }
    }
}

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var workoutPlanScreenIdentity = UUID()
    @State private var isPresentingWorkoutPlanDraft = false
    @State private var workoutPlanDraftBeingPresented: WorkoutPlanDraft?
    @State private var workoutPlanEditorAppliedDraft = false
    @State private var queuedWorkoutPlanDraftBeingPresented: WorkoutPlanDraft?

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatScreen()
                .tabItem { Label("今天", systemImage: "sun.max.fill") }
                .tag(0)

            DashboardScreen()
                .tabItem { Label("趋势", systemImage: "chart.xyaxis.line") }
                .tag(1)

            HistoryScreen()
                .tabItem { Label("记录", systemImage: "list.bullet.rectangle") }
                .tag(2)

            SettingsScreen()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .tint(OrbitPalette.gold)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(Color(.systemBackground).opacity(0.96), for: .tabBar)
        .sheet(
            isPresented: $isPresentingWorkoutPlanDraft,
            onDismiss: presentNextQueuedWorkoutPlanDraft
        ) {
            WorkoutPlanScreen()
                .id(workoutPlanScreenIdentity)
        }
        .onAppear {
            consumeSystemIntent()
            presentPendingAppIntentDrafts()
        }
        .onChange(of: appState.pendingSystemIntent) { _, _ in consumeSystemIntent() }
        .onChange(of: appState.pendingMealText) { _, mealText in
            guard mealText != nil else { return }
            AppIntentInbox.clearMealText()
            selectedTab = 0
        }
        .onChange(of: appState.pendingWorkoutPlan) { _, draft in
            guard let draft else {
                if let queuedDraft = queuedWorkoutPlanDraftBeingPresented {
                    AppIntentInbox.acknowledgeQueuedWorkoutPlan(queuedDraft)
                    queuedWorkoutPlanDraftBeingPresented = nil
                }
                if isPresentingWorkoutPlanDraft {
                    workoutPlanEditorAppliedDraft = true
                } else {
                    workoutPlanDraftBeingPresented = nil
                    workoutPlanEditorAppliedDraft = false
                }
                return
            }
            presentWorkoutPlanDraft(draft)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            if let destination = AppIntentInbox.consumeDestination() {
                appState.pendingSystemIntent = destination
            }
            AppIntentInbox.receivePendingDrafts(
                receiveWorkoutPlan: !isPresentingWorkoutPlanDraft
            )
            consumeSystemIntent()
        }
    }

    private func presentPendingAppIntentDrafts() {
        if appState.pendingMealText != nil {
            AppIntentInbox.clearMealText()
            selectedTab = 0
        }
        guard !isPresentingWorkoutPlanDraft else { return }
        if let pendingDraft = appState.pendingWorkoutPlan {
            presentWorkoutPlanDraft(pendingDraft)
        } else if let queuedDraft = AppIntentInbox.nextQueuedWorkoutPlan() {
            queuedWorkoutPlanDraftBeingPresented = queuedDraft
            appState.pendingWorkoutPlan = queuedDraft
        } else if let inboxDraft = AppIntentInbox.consumeWorkoutPlan() {
            appState.pendingWorkoutPlan = inboxDraft
        }
    }

    private func presentWorkoutPlanDraft(_ draft: WorkoutPlanDraft) {
        guard workoutPlanDraftBeingPresented != draft else { return }
        if isPresentingWorkoutPlanDraft {
            if AppIntentInbox.enqueueWorkoutPlan(draft) {
                AppIntentInbox.clearWorkoutPlan()
                appState.pendingWorkoutPlan = workoutPlanEditorAppliedDraft
                    ? nil
                    : workoutPlanDraftBeingPresented
            } else {
                appState.pendingWorkoutPlan = workoutPlanEditorAppliedDraft
                    ? draft
                    : workoutPlanDraftBeingPresented
            }
            return
        }
        AppIntentInbox.clearWorkoutPlan()
        workoutPlanDraftBeingPresented = draft
        workoutPlanEditorAppliedDraft = false
        workoutPlanScreenIdentity = UUID()
        isPresentingWorkoutPlanDraft = true
    }

    private func presentNextQueuedWorkoutPlanDraft() {
        workoutPlanDraftBeingPresented = nil
        workoutPlanEditorAppliedDraft = false
        if let pendingDraft = appState.pendingWorkoutPlan {
            presentWorkoutPlanDraft(pendingDraft)
            return
        }
        if let queuedDraft = AppIntentInbox.nextQueuedWorkoutPlan() {
            queuedWorkoutPlanDraftBeingPresented = queuedDraft
            appState.pendingWorkoutPlan = queuedDraft
        } else if let inboxDraft = AppIntentInbox.consumeWorkoutPlan() {
            appState.pendingWorkoutPlan = inboxDraft
        }
    }

    private func consumeSystemIntent() {
        let destination: DensosoAppIntentDestination
        if let pending = appState.pendingSystemIntent {
            destination = pending
            AppIntentInbox.clearDestination()
            appState.pendingSystemIntent = nil
        } else if let pending = AppIntentInbox.consumeDestination() {
            destination = pending
        } else {
            return
        }

        selectedTab = 0
        switch destination {
        case .todayStatus, .todayGuidance, .openToday:
            appState.shouldScrollToDailyLoop = true
            appState.shouldFocusComposer = false
        case .startRecording:
            appState.shouldScrollToDailyLoop = false
            appState.shouldFocusComposer = true
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [UserProfile.self, MealRecord.self])
        .environment(Dependencies())
        .environment(AppState.shared)
}
