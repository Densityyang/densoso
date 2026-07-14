import SwiftUI
import SwiftData

/// 首次启动：配置 API Key 和基础资料
struct OnboardingView: View {
    @Environment(Dependencies.self) private var dependencies
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @State private var apiKey = ""
    @State private var name = ""
    @State private var sex = "male"
    @State private var height = "170"
    @State private var weight = "70"
    @State private var activity = "sedentary"
    @State private var deficitTarget = "500"
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("API Key") {
                    TextField("DeepSeek API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("您的 API Key 仅存储在 iOS Keychain 中，不会上传到任何服务器。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("基础资料") {
                    TextField("怎么称呼你", text: $name)
                    Picker("性别", selection: $sex) {
                        Text("男").tag("male")
                        Text("女").tag("female")
                        Text("其他").tag("other")
                    }
                    TextField("身高 (cm)", text: $height)
                        .keyboardType(.decimalPad)
                    TextField("体重 (kg)", text: $weight)
                        .keyboardType(.decimalPad)
                    Picker("日常活动量", selection: $activity) {
                        Text("久坐不动").tag("sedentary")
                        Text("轻度活动").tag("light")
                        Text("中度活动").tag("moderate")
                        Text("活跃").tag("active")
                        Text("高强度").tag("veryActive")
                    }
                    TextField("每日目标缺口 (kcal)", text: $deficitTarget)
                        .keyboardType(.numberPad)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Text("开始使用")
                            if isSaving { ProgressView() }
                        }
                    }
                    .disabled(apiKey.isEmpty || isSaving)
                }
            }
            .navigationTitle("欢迎使用 densoso")
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil

        do {
            try KeychainStore.shared.saveAPIKey(apiKey)

            let profile = UserProfile(
                name: name,
                biologicalSex: sex,
                dateOfBirth: Date(timeIntervalSince1970: 0),  // TODO: 出生日期
                heightCm: Double(height) ?? 170,
                weightKg: Double(weight) ?? 70,
                activityLevel: activity,
                dailyDeficitTarget: Int(deficitTarget) ?? 500
            )
            modelContext.insert(profile)
            try modelContext.save()

            await MainActor.run {
                appState.isOnboarded = true
                appState.userProfile = profile
            }
        } catch {
            errorMessage = "保存失败: \(error.localizedDescription)"
        }

        isSaving = false
    }
}

#Preview {
    OnboardingView()
        .modelContainer(for: UserProfile.self)
        .environment(Dependencies())
        .environment(AppState.shared)
}
