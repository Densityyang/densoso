import SwiftData
import SwiftUI

/// First launch remains a local-first, explicit-consent flow. The visual steps
/// reorganize the existing fields without changing persistence semantics.
struct OnboardingView: View {
    private enum Step: Int {
        case intelligence
        case profile
    }

    @Environment(Dependencies.self) private var dependencies
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @State private var step: Step = .intelligence
    @State private var apiKey = ""
    @State private var name = ""
    @State private var sex = "male"
    @State private var height = "170"
    @State private var weight = "70"
    @State private var activity = "sedentary"
    @State private var deficitTarget = "500"
    @State private var intelligenceMode: IntelligenceMode = .localOnly
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                    Section {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                OrbitStatusBadge(
                                    text: step == .intelligence ? "1 / 2" : "2 / 2",
                                    tone: .gold
                                )
                                Spacer()
                                Text("LOCAL-FIRST")
                                    .font(.caption2.weight(.semibold))
                                    .tracking(1.2)
                                    .foregroundStyle(.secondary)
                            }

                            OrbitScreenHeader(
                                eyebrow: step == .intelligence ? "Trust before data" : "Your energy baseline",
                                title: step == .intelligence
                                    ? "你的记录，先由你决定去向。"
                                    : "建立你的能量基线。",
                                subtitle: step == .intelligence
                                    ? "处理方式由你选择；任何健康记录在确认前都不会保存。"
                                    : "资料保存在本机，可在设置中更新。"
                            )
                        }
                        .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    if step == .intelligence {
                        intelligenceSections
                    } else {
                        profileSections
                    }

                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(OrbitPalette.coral)
                        }
                    }

                    Section {
                        Button {
                            if step == .intelligence {
                                withAnimation(.easeInOut) { step = .profile }
                            } else {
                                Task { await save() }
                            }
                        } label: {
                            HStack {
                                Text(step == .intelligence ? "继续" : "保存并开始")
                                Spacer()
                                if isSaving {
                                    ProgressView()
                                } else {
                                    Image(systemName: step == .intelligence ? "arrow.right" : "checkmark")
                                }
                            }
                        }
                        .disabled(
                            (step == .intelligence && intelligenceMode == .cloudDeepSeek && apiKey.isEmpty)
                                || isSaving
                        )
                    }
            }
            .orbitScrollBackground()
            .navigationTitle("欢迎使用 densoso")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step == .profile {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("返回", systemImage: "chevron.left") {
                            withAnimation(.easeInOut) { step = .intelligence }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var intelligenceSections: some View {
        Section("处理方式") {
            Picker("处理方式", selection: $intelligenceMode) {
                Text("设备端").tag(IntelligenceMode.localOnly)
                Text("DeepSeek").tag(IntelligenceMode.cloudDeepSeek)
            }
            .pickerStyle(.segmented)

            Label {
                Text(intelligenceExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: intelligenceMode == .localOnly ? "iphone" : "cloud")
                    .foregroundStyle(intelligenceMode == .localOnly ? OrbitPalette.green : OrbitPalette.blue)
            }
        }

        if intelligenceMode == .cloudDeepSeek {
            Section("DeepSeek API Key") {
                SecureField("输入 API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("密钥保存在 iOS Keychain，只在你主动提交云端请求时用于认证。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var profileSections: some View {
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
        }

        Section("目标") {
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
    }

    private var intelligenceExplanation: String {
        switch intelligenceMode {
        case .localOnly:
            "餐食与训练文字保留在本机。设备端能力不可用时会安全回退，输入不会自动上传或保存。"
        case .cloudDeepSeek:
            "仅把你主动提交的文字发送给 DeepSeek；写入健康数据仍需再次确认。"
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            if intelligenceMode == .cloudDeepSeek {
                try KeychainStore.shared.saveAPIKey(apiKey)
            }
            dependencies.intelligencePreferences.mode = intelligenceMode

            let profile = UserProfile(
                name: name,
                biologicalSex: sex,
                dateOfBirth: Date(timeIntervalSince1970: 0),
                heightCm: Double(height) ?? 170,
                weightKg: Double(weight) ?? 70,
                activityLevel: activity,
                dailyDeficitTarget: Int(deficitTarget) ?? 500
            )
            modelContext.insert(profile)
            try modelContext.save()

            appState.isOnboarded = true
            appState.userProfile = profile
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

#Preview {
    OnboardingView()
        .modelContainer(for: UserProfile.self, inMemory: true)
        .environment(Dependencies())
        .environment(AppState.shared)
}
