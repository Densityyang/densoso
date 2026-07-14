import SwiftUI
import SwiftData
import UIKit

struct SettingsScreen: View {
    @Environment(Dependencies.self) private var dependencies
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Query private var profiles: [UserProfile]
    @State private var apiKey = ""
    @State private var showKeySaved = false
    @State private var exportURL: URL?
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            Form {
                Section("API Key") {
                    TextField("DeepSeek API Key", text: $apiKey)
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

                Section("关于") {
                    Text("densoso v1.0")
                    Text("本地优先 · 语音驱动 · 中餐热量估算")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .task {
                if let saved = try? KeychainStore.shared.readAPIKey() {
                    apiKey = String(saved.prefix(8)) + "..."
                }
            }
            .sheet(item: $exportURL) { url in
                ShareSheet(items: [url])
            }
        }
    }

    private func saveKey() async {
        guard !apiKey.isEmpty else { return }
        try? KeychainStore.shared.saveAPIKey(apiKey)
        showKeySaved = true
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        showKeySaved = false
    }

    private func exportData() async {
        do {
            let url = try await dependencies.exportService.exportJSON(context: modelContext)
            exportURL = url
        } catch {
            dependencies.exportService.lastError = error.localizedDescription
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
