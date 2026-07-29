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
    var body: some View {
        TabView {
            ChatScreen()
                .tabItem { Label("对话", systemImage: "bubble.left.fill") }

            DashboardScreen()
                .tabItem { Label("数据", systemImage: "chart.bar.fill") }

            HistoryScreen()
                .tabItem { Label("历史", systemImage: "clock.fill") }

            WorkoutPlanScreen()
                .tabItem { Label("计划", systemImage: "figure.strengthtraining.traditional") }

            SettingsScreen()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .tint(OrbitPalette.gold)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(Color(.systemBackground).opacity(0.96), for: .tabBar)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [UserProfile.self, MealRecord.self])
        .environment(Dependencies())
        .environment(AppState.shared)
}
