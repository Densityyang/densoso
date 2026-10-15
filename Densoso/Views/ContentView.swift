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
                .tabItem { Label("今天", systemImage: "sun.max.fill") }

            DashboardScreen()
                .tabItem { Label("趋势", systemImage: "chart.xyaxis.line") }

            HistoryScreen()
                .tabItem { Label("记录", systemImage: "list.bullet.rectangle") }

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
