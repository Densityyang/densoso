import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isOnboarded {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            ChatScreen()
                .tabItem { Label("对话", systemImage: "bubble.left.fill") }

            DashboardScreen()
                .tabItem { Label("数据", systemImage: "chart.bar.fill") }

            HistoryScreen()
                .tabItem { Label("历史", systemImage: "clock.fill") }

            SettingsScreen()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [UserProfile.self, MealRecord.self])
        .environment(Dependencies())
        .environment(AppState.shared)
}
