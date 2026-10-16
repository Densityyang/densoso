import SwiftUI
import SwiftData

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
        .onAppear(perform: consumeSystemIntent)
        .onChange(of: appState.pendingSystemIntent) { _, _ in consumeSystemIntent() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            if let destination = AppIntentInbox.consumeDestination() {
                appState.pendingSystemIntent = destination
            }
            consumeSystemIntent()
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
