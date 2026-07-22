import SwiftUI
import SwiftData
import UIKit

struct SettingsScreen: View {
    @Environment(Dependencies.self) private var dependencies
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Query private var profiles: [UserProfile]
    @State private var apiKey = ""
    @State private var hasSavedAPIKey = false
    @State private var showKeySaved = false
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var isAuthorizingHealth = false
    @State private var healthAuthorizationError: String?
    @State private var healthKitWorkoutImporter = HealthKitWorkoutImporter()
    @State private var workoutRouteImporter = WorkoutRouteImporter()

    var body: some View {
        NavigationStack {
            Form {
                Section("API Key") {
                    SecureField(hasSavedAPIKey ? "输入新 API Key 以替换现有密钥" : "DeepSeek API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存到 Keychain") {
                        Task { await saveKey() }
                    }
                    if showKeySaved {
                        Text("已保存")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Text("密钥保存在本机 Keychain；发起云端请求时会发送给 DeepSeek，用于认证。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let profile = profiles.first {
                    Section("个人资料") {
                        Text("身高: \(String(format: "%.1f", profile.heightCm)) cm")
                        Text("体重: \(String(format: "%.1f", profile.weightKg)) kg")
                        Text("日目标缺口: \(profile.dailyDeficitTarget) kcal")
                    }
                }

                Section("数据") {
                    Button("导出备份") {
                        Task { await exportData() }
                    }
                    .disabled(dependencies.exportService.isExporting)

                    if dependencies.exportService.isExporting {
                        ProgressView()
                    }
                }

                Section("Apple Health") {
                    Button(dependencies.healthKitService.isAuthorized ? "同步训练记录" : "连接 Apple Health") {
                        Task { await authorizeAndImportHealthData() }
                    }
                    .disabled(isAuthorizingHealth)

                    if isAuthorizingHealth {
                        ProgressView()
                    }

                    if let healthAuthorizationError {
                        Text(healthAuthorizationError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("关于") {
                    Text("densoso v1.0")
                    Text("本地优先 · 语音驱动 · 中餐热量估算")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .task {
                hasSavedAPIKey = (try? KeychainStore.shared.readAPIKey()) != nil
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = exportURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    private func saveKey() async {
        guard !apiKey.isEmpty else { return }
        try? KeychainStore.shared.saveAPIKey(apiKey)
        apiKey = ""
        hasSavedAPIKey = true
        showKeySaved = true
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        showKeySaved = false
    }

    private func exportData() async {
        do {
            let url = try await dependencies.exportService.exportJSON(context: modelContext)
            exportURL = url
            showShareSheet = true
        } catch {
            dependencies.exportService.lastError = error.localizedDescription
        }
    }

    private func authorizeAndImportHealthData() async {
        isAuthorizingHealth = true
        healthAuthorizationError = nil
        defer { isAuthorizingHealth = false }

        do {
            try await dependencies.healthKitService.requestAuthorization()
            healthKitWorkoutImporter.importChanges(in: modelContext)
            workoutRouteImporter.importPendingRoutes(in: modelContext)
        } catch {
            healthAuthorizationError = "Apple Health authorization failed: \(error.localizedDescription)"
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    SettingsScreen()
        .modelContainer(for: UserProfile.self)
        .environment(Dependencies())
        .environment(AppState.shared)
}
