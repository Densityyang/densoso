import SwiftData
import SwiftUI
import UIKit

struct SettingsScreen: View {
    @Environment(Dependencies.self) private var dependencies
    @Environment(\.modelContext) private var modelContext

    @Query private var profiles: [UserProfile]
    @Query(sort: \HealthKitImportCursor.updatedAt, order: .reverse) private var healthImportCursors: [HealthKitImportCursor]

    @State private var apiKey = ""
    @State private var hasSavedAPIKey = false
    @State private var statusMessage: String?
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var isAuthorizingHealth = false
    @State private var healthAuthorizationError: String?
    @State private var isEditingProfile = false
    @State private var healthKitWorkoutImporter = HealthKitWorkoutImporter()
    @State private var workoutRouteImporter = WorkoutRouteImporter()

    var body: some View {
        NavigationStack {
            Form {
                    Section {
                        OrbitScreenHeader(
                            eyebrow: "Explain the boundary",
                            title: "权限和数据状态，都给出下一步。",
                            subtitle: "设备端、云端、签名能力和系统授权分层展示；不会用一条红字混在一起。"
                        )
                        .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    intelligenceSection
                    profileSection
                    capabilitySections
                    dataSection

                    if let statusMessage {
                        Section("状态") {
                            Label(statusMessage, systemImage: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(OrbitPalette.green)
                        }
                    }

                    if let error = healthAuthorizationError ?? dependencies.exportService.lastError {
                        Section("需要处理") {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(OrbitPalette.coral)
                        }
                    }

                    Section("关于") {
                        LabeledContent("版本", value: "densoso v1.0")
                        Text("本地优先 · 语音驱动 · 可确认的健康记录")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
            }
            .orbitScrollBackground()
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                hasSavedAPIKey = (try? KeychainStore.shared.readAPIKey()) != nil
                await refreshDiagnostics()
            }
            .onChange(of: healthImportCursors.first?.updatedAt) { _, _ in
                Task { await refreshDiagnostics() }
            }
            .sheet(isPresented: $showShareSheet) {
                if let exportURL {
                    ShareSheet(items: [exportURL])
                }
            }
            .sheet(isPresented: $isEditingProfile) {
                if let profile = profiles.first {
                    ProfileEditorSheet(profile: profile)
                        .presentationBackground {
                            OrbitBackground()
                        }
                }
            }
        }
    }

    private var intelligenceSection: some View {
        Group {
            Section("处理方式") {
                Picker("处理方式", selection: Binding(
                    get: { dependencies.intelligencePreferences.mode },
                    set: { dependencies.intelligencePreferences.mode = $0 }
                )) {
                    Text("设备端").tag(IntelligenceMode.localOnly)
                    Text("DeepSeek").tag(IntelligenceMode.cloudDeepSeek)
                }
                .pickerStyle(.segmented)

                Text("设备端模式不会把餐食和训练文字发送给 DeepSeek；云端模式只发送你主动提交的文字。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("DeepSeek API Key") {
                SecureField(hasSavedAPIKey ? "输入新 Key 以替换" : "输入 API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存到 Keychain", systemImage: "key.fill") {
                    Task { await saveKey() }
                }
                .disabled(apiKey.isEmpty)
                Text("密钥保存在本机 Keychain，仅用于你选择的 DeepSeek 请求。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var profileSection: some View {
        if let profile = profiles.first {
            Section("个人资料") {
                LabeledContent("称呼", value: profile.name.isEmpty ? "未填写" : profile.name)
                LabeledContent(
                    "身高",
                    value: "\(profile.heightCm.formatted(.number.precision(.fractionLength(1)))) cm"
                )
                LabeledContent(
                    "体重",
                    value: "\(profile.weightKg.formatted(.number.precision(.fractionLength(1)))) kg"
                )
                LabeledContent("日目标缺口", value: "\(profile.dailyDeficitTarget) kcal")
                Button("编辑个人资料", systemImage: "person.crop.circle") {
                    isEditingProfile = true
                }
            }
        }
    }

    private var capabilitySections: some View {
        let snapshot = dependencies.capabilityDiagnostics.snapshot
        return Group {
            Section("Apple Health") {
                CapabilityRow(
                    title: "设备 HealthKit",
                    detail: "当前设备是否支持健康数据",
                    value: snapshot.healthDataAvailable ? "可用" : "不可用",
                    tone: snapshot.healthDataAvailable ? .success : .danger
                )
                CapabilityRow(
                    title: "工程能力",
                    detail: "HealthKit entitlement 已配置；真机签名在授权时验证",
                    value: snapshot.healthKitCapabilityConfigured ? "已配置" : "未配置",
                    tone: snapshot.healthKitCapabilityConfigured ? .success : .danger
                )
                CapabilityRow(
                    title: "膳食能量写入",
                    detail: "HealthKit 允许公开查询的写入状态",
                    state: snapshot.dietaryEnergyWritePermission
                )
                CapabilityRow(
                    title: "健康数据读取",
                    detail: "Apple 不向应用公开读取权限是否被拒绝",
                    state: snapshot.healthReadPermission
                )
                CapabilityRow(
                    title: "授权请求",
                    detail: "系统是否仍需展示 HealthKit 授权页",
                    value: snapshot.healthAuthorizationRequest.displayName,
                    tone: snapshot.healthAuthorizationRequest == .shouldRequest ? .gold : .neutral
                )

                if let lastImportAt = snapshot.lastHealthImportAt {
                    LabeledContent("最近导入") {
                        Text(lastImportAt, format: .dateTime.month().day().hour().minute())
                    }
                } else {
                    LabeledContent("最近导入", value: "尚未完成")
                }

                Button(
                    dependencies.healthKitService.isAuthorized ? "同步训练记录" : "连接 Apple Health",
                    systemImage: "heart.fill"
                ) {
                    Task { await authorizeAndImportHealthData() }
                }
                .disabled(
                    isAuthorizingHealth
                        || !snapshot.healthDataAvailable
                        || !snapshot.healthKitCapabilityConfigured
                )

                if isAuthorizingHealth {
                    ProgressView("正在请求系统授权")
                }
            }

            Section("语音能力") {
                CapabilityRow(
                    title: "麦克风",
                    detail: "AVAudioApplication 录音权限",
                    state: snapshot.microphonePermission
                )
                CapabilityRow(
                    title: "语音识别",
                    detail: "兼容路径的 Speech 授权状态",
                    state: snapshot.speechRecognitionPermission
                )
                CapabilityRow(
                    title: "设备端转写",
                    detail: "iOS 26 SpeechAnalyzer 运行时能力",
                    value: snapshot.modernSpeechAvailable ? "可用" : "使用兼容路径",
                    tone: snapshot.modernSpeechAvailable ? .success : .blue
                )
                Button("刷新能力状态", systemImage: "arrow.clockwise") {
                    Task { await refreshDiagnostics() }
                }
                .disabled(dependencies.capabilityDiagnostics.isRefreshing)
            }
        }
    }

    private var dataSection: some View {
        Section("数据") {
            Button("导出 JSON 备份", systemImage: "square.and.arrow.up") {
                Task { await exportData() }
            }
            .disabled(dependencies.exportService.isExporting)

            if dependencies.exportService.isExporting {
                ProgressView("正在生成备份")
            }
        }
    }

    private func saveKey() async {
        guard !apiKey.isEmpty else { return }
        do {
            try KeychainStore.shared.saveAPIKey(apiKey)
            apiKey = ""
            hasSavedAPIKey = true
            statusMessage = "API Key 已保存到 Keychain。"
        } catch {
            statusMessage = nil
            healthAuthorizationError = "无法保存 API Key：\(error.localizedDescription)"
        }
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

    private func refreshDiagnostics() async {
        await dependencies.capabilityDiagnostics.refresh(
            lastHealthImportAt: healthImportCursors.first?.updatedAt
        )
    }

    private func authorizeAndImportHealthData() async {
        isAuthorizingHealth = true
        healthAuthorizationError = nil
        defer { isAuthorizingHealth = false }

        do {
            try await dependencies.healthKitService.requestAuthorization()
            healthKitWorkoutImporter.importChanges(in: modelContext)
            workoutRouteImporter.importPendingRoutes(in: modelContext)
            statusMessage = "已请求 HealthKit 导入；完成后会更新最近导入时间。"
            await refreshDiagnostics()
        } catch {
            healthAuthorizationError = "Apple Health 授权失败：\(error.localizedDescription)"
            await refreshDiagnostics()
        }
    }
}

private struct CapabilityRow: View {
    let title: String
    let detail: String
    let value: String
    let tone: OrbitStatusBadge.Tone

    init(title: String, detail: String, value: String, tone: OrbitStatusBadge.Tone) {
        self.title = title
        self.detail = detail
        self.value = value
        self.tone = tone
    }

    init(title: String, detail: String, state: CapabilityPermissionState) {
        self.title = title
        self.detail = detail
        self.value = state.displayName
        switch state {
        case .authorized:
            self.tone = .success
        case .denied, .unavailable:
            self.tone = .danger
        case .notDetermined:
            self.tone = .gold
        case .privacyProtected:
            self.tone = .blue
        case .unknown:
            self.tone = .neutral
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            OrbitStatusBadge(text: value, tone: tone)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let profile: UserProfile

    @State private var name: String
    @State private var sex: String
    @State private var dateOfBirth: Date
    @State private var height: String
    @State private var weight: String
    @State private var activity: String
    @State private var deficitTarget: String
    @State private var validationError: String?

    init(profile: UserProfile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _sex = State(initialValue: profile.biologicalSex)
        _dateOfBirth = State(initialValue: profile.dateOfBirth)
        _height = State(initialValue: String(format: "%.1f", profile.heightCm))
        _weight = State(initialValue: String(format: "%.1f", profile.weightKg))
        _activity = State(initialValue: profile.activityLevel)
        _deficitTarget = State(initialValue: String(profile.dailyDeficitTarget))
    }

    var body: some View {
        NavigationStack {
            Form {
                    Section("基础资料") {
                        TextField("称呼", text: $name)
                        Picker("性别", selection: $sex) {
                            Text("男").tag("male")
                            Text("女").tag("female")
                            Text("其他").tag("other")
                        }
                        DatePicker("出生日期", selection: $dateOfBirth, in: ...Date(), displayedComponents: .date)
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

                    if let validationError {
                        Section {
                            Text(validationError)
                                .font(.footnote)
                                .foregroundStyle(OrbitPalette.coral)
                        }
                    }
            }
            .orbitScrollBackground()
            .navigationTitle("编辑个人资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { save() }
                }
            }
        }
    }

    private func save() {
        guard let heightValue = Double(height), (80...250).contains(heightValue),
              let weightValue = Double(weight), (20...500).contains(weightValue),
              let targetValue = Int(deficitTarget), (0...5_000).contains(targetValue) else {
            validationError = "请检查身高、体重和目标缺口的数值范围。"
            return
        }

        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.biologicalSex = sex
        profile.dateOfBirth = dateOfBirth
        profile.heightCm = heightValue
        if abs(profile.weightKg - weightValue) > 0.001 {
            profile.updateWeight(weightValue)
        }
        profile.activityLevel = activity
        profile.dailyDeficitTarget = targetValue
        profile.updatedAt = Date()

        do {
            try modelContext.save()
            dismiss()
        } catch {
            validationError = "保存失败：\(error.localizedDescription)"
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
        .modelContainer(for: [UserProfile.self, HealthKitImportCursor.self], inMemory: true)
        .environment(Dependencies())
}
