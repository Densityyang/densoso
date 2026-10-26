import SwiftData
import SwiftUI
import UIKit
import DensosoDomain

struct SettingsScreen: View {
    private struct PendingHealthPolicyExpansion: Equatable {
        let provider: ProviderID
        let dataClass: ProviderDataClass
    }

    private enum PendingCloudPolicyExpansion {
        case health(PendingHealthPolicyExpansion)
        case conversationHistory(ProviderID)
    }

    @Environment(Dependencies.self) private var dependencies
    @Environment(\.modelContext) private var modelContext

    @Query private var profiles: [UserProfile]
    @Query(sort: \HealthKitImportCursor.updatedAt, order: .reverse) private var healthImportCursors: [HealthKitImportCursor]

    @State private var apiKey = ""
    @State private var hasSavedAPIKey = false
    @State private var qwenAPIKey = ""
    @State private var hasSavedQwenAPIKey = false
    @State private var deepSeekTextConsent = false
    @State private var deepSeekConversationHistoryConsent = false
    @State private var deepSeekMealImageConsent = false
    @State private var deepSeekHealthContextClasses: Set<ProviderDataClass> = []
    @State private var qwenTextConsent = false
    @State private var qwenConversationHistoryConsent = false
    @State private var qwenSpeechConsent = false
    @State private var qwenMealImageConsent = false
    @State private var qwenHealthContextClasses: Set<ProviderDataClass> = []
    @State private var pendingCloudPolicyExpansion: PendingCloudPolicyExpansion?
    @State private var isConfirmingCloudPolicyExpansion = false
    @State private var deepSeekUsage = "尚无用量"
    @State private var qwenUsage = "尚无用量"
    @State private var statusMessage: String?
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var isExportingDiagnostics = false
    @State private var isAuthorizingHealth = false
    @State private var healthAuthorizationError: String?
    @State private var isEditingProfile = false
    @State private var goalTargetWeight = ""
    @State private var goalDailyDeficit = ""
    @State private var goalDailyProtein = ""
    @State private var isConfirmingGoalSave = false
    @State private var notificationError: String?

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
                    MealPortionPriorSettingsSection()
                    goalsSection
                    capabilitySections
                    notificationSection
                    dataSection

                    if let statusMessage {
                        Section("状态") {
                            Label(statusMessage, systemImage: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(OrbitPalette.green)
                        }
                    }

                    if let error = healthAuthorizationError ?? notificationError ?? dependencies.exportService.lastError {
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
            .confirmationDialog(
                "确认云端数据授权变更？",
                isPresented: $isConfirmingCloudPolicyExpansion,
                titleVisibility: .visible
            ) {
                switch pendingCloudPolicyExpansion {
                case .some(.health(let pending)):
                    Button("允许上传\(pending.dataClass.healthContextTitle ?? "健康")历史汇总") {
                        Task { await confirmHealthPolicyExpansion(pending) }
                    }
                case .some(.conversationHistory(let provider)):
                    Button("允许向\(provider == .deepSeek ? "DeepSeek" : "Qwen")发送此前聊天记录") {
                        Task {
                            await saveConversationHistoryConsent(
                                provider: provider,
                                granted: true,
                                confirmedAt: Date()
                            )
                        }
                    }
                case nil:
                    EmptyView()
                }
                Button("取消", role: .cancel) {
                    pendingCloudPolicyExpansion = nil
                }
            } message: {
                switch pendingCloudPolicyExpansion {
                case .health(let pending)?:
                    Text("仅允许所选的\(pending.dataClass.healthContextTitle ?? "健康")类别用于\(pending.provider == .deepSeek ? "DeepSeek" : "Qwen")后续请求。扩权会保存新的本地 policy revision；你可以随时撤销。")
                case .some(.conversationHistory(_)):
                    Text("此前聊天记录与本轮你主动提交的文字是两项独立权限。确认后，后续请求只会包含仍符合当前云端健康类别策略且 policy revision 一致的完整对话轮次。")
                case nil:
                    Text("确认后会保存新的本地云端授权 policy revision。")
                }
            }
            .task {
                await loadGoalFields()
                if !AppLaunchConfiguration.current.isUITesting {
                    hasSavedAPIKey = (try? KeychainStore.shared.readAPIKey()) != nil
                    hasSavedQwenAPIKey = (try? KeychainStore.shared.readModelStudioAPIKey()) != nil
                    await refreshProviderGovernance()
                    await refreshDiagnostics()
                }
            }
            .onChange(of: healthImportCursors.first?.updatedAt) { _, _ in
                Task {
                    await refreshDiagnostics()
                    _ = try? await dependencies.healthIntelligenceService.refresh()
                }
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
                    Text("Qwen").tag(IntelligenceMode.cloudQwen)
                }
                .pickerStyle(.segmented)

                Text("设备端模式不上传文字；DeepSeek/Qwen 仅在你显式选择并同意文字上传后调用，不会静默切换供应商。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("DeepSeek API Key") {
                SecureField(hasSavedAPIKey ? "输入新 Key 以替换" : "输入 API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存到 Keychain", systemImage: "key.fill") {
                    Task { await saveDeepSeekKey() }
                }
                .disabled(apiKey.isEmpty)
                Text("密钥保存在本机 Keychain，仅用于你选择的 DeepSeek 请求。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("同意向 DeepSeek 上传主动提交的健康文字", isOn: $deepSeekTextConsent)
                    .onChange(of: deepSeekTextConsent) { _, value in
                        Task { await saveConsent(provider: .deepSeek, granted: value) }
                }
                healthContextConsentControls(provider: .deepSeek, selection: $deepSeekHealthContextClasses)
                conversationHistoryConsentControl(provider: .deepSeek, selection: $deepSeekConversationHistoryConsent)
                Text("本轮主动提交的文字由上方单独授权；此前聊天记录与历史健康汇总使用独立权限。未配置健康类别时不会自动附加健康上下文；撤销后立即从后续请求与续轮中移除。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("同意向 DeepSeek 上传处理后的餐食照片", isOn: $deepSeekMealImageConsent)
                    .onChange(of: deepSeekMealImageConsent) { _, value in
                        Task {
                            await saveConsent(
                                provider: .deepSeek,
                                dataClass: .mealImage,
                                granted: value
                            )
                        }
                    }
                Text("餐食照片经本机缩放并移除元数据；原图不留存。仅在选择 DeepSeek 且启用此项后，照片才随本次 Agent 请求上传。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("本月用量", value: deepSeekUsage)
                TextField(
                    "软提醒预算 USD/月",
                    value: Binding(
                        get: { Double(dependencies.providerConfiguration.deepSeekMonthlyBudgetMicros) / 1_000_000 },
                        set: {
                            guard $0.isFinite,
                                  $0 >= 0,
                                  $0 < Double(Int64.max) / 1_000_000 else { return }
                            dependencies.providerConfiguration.deepSeekMonthlyBudgetMicros =
                                Int64($0 * 1_000_000)
                        }
                    ),
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.decimalPad)
            }

            Section("Qwen Model Studio") {
                SecureField(hasSavedQwenAPIKey ? "输入新 Key 以替换" : "输入 Model Studio Key", text: $qwenAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Workspace ID", text: Binding(
                    get: { dependencies.providerConfiguration.qwenWorkspaceID },
                    set: { dependencies.providerConfiguration.qwenWorkspaceID = $0 }
                ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LabeledContent("区域", value: "北京")
                Button("保存到 Keychain", systemImage: "key.fill") {
                    Task { await saveQwenKey() }
                }
                .disabled(qwenAPIKey.isEmpty)
                Toggle("同意向 Qwen 上传主动提交的健康文字", isOn: $qwenTextConsent)
                    .onChange(of: qwenTextConsent) { _, value in
                        Task { await saveConsent(provider: .qwen, granted: value) }
                }
                healthContextConsentControls(provider: .qwen, selection: $qwenHealthContextClasses)
                conversationHistoryConsentControl(provider: .qwen, selection: $qwenConversationHistoryConsent)
                Text("本轮主动提交的文字由上方单独授权；此前聊天记录与历史健康汇总使用独立权限。未配置健康类别时不会自动附加健康上下文；撤销后立即从后续请求与续轮中移除。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle(
                    "本地转写失败时启用 Qwen 单次语音兜底",
                    isOn: Binding(
                        get: { dependencies.providerConfiguration.qwenSpeechFallbackEnabled },
                        set: { dependencies.providerConfiguration.qwenSpeechFallbackEnabled = $0 }
                    )
                )
                Toggle("同意向 Qwen 上传单次临时音频", isOn: $qwenSpeechConsent)
                    .onChange(of: qwenSpeechConsent) { _, value in
                        Task {
                            await saveConsent(
                                provider: .qwen,
                                dataClass: .speechAudio,
                                granted: value
                            )
                        }
                    }
                Toggle(
                    "启用 Qwen 开放式餐食照片观察",
                    isOn: .constant(false)
                )
                .disabled(true)
                Toggle("同意向 Qwen 上传处理后的餐食照片", isOn: $qwenMealImageConsent)
                    .onChange(of: qwenMealImageConsent) { _, value in
                        Task {
                            await saveConsent(
                                provider: .qwen,
                                dataClass: .mealImage,
                                granted: value
                            )
                        }
                    }
                Text("Qwen 开放照片在真实照片质量门禁完成前保持关闭；开放照片默认走 DeepSeek，且需单独授权，不会自动切到 Qwen。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("本月用量", value: qwenUsage)
                TextField(
                    "软提醒预算 CNY/月",
                    value: Binding(
                        get: { Double(dependencies.providerConfiguration.qwenMonthlyBudgetMicros) / 1_000_000 },
                        set: {
                            guard $0.isFinite,
                                  $0 >= 0,
                                  $0 < Double(Int64.max) / 1_000_000 else { return }
                            dependencies.providerConfiguration.qwenMonthlyBudgetMicros =
                                Int64($0 * 1_000_000)
                        }
                    ),
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.decimalPad)
                Text("文本、qwen3-asr-flash 与 qwen3.7-flash-2026-07-15 均固定北京区域；音频和处理后照片分别取得同意，原图不会保存。")
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

    private var goalsSection: some View {
        Section("健康目标") {
            TextField("目标体重 kg（可选）", text: $goalTargetWeight)
                .keyboardType(.decimalPad)
            TextField("每日缺口 kcal（可选）", text: $goalDailyDeficit)
                .keyboardType(.numberPad)
            TextField("每日蛋白质 g（可选）", text: $goalDailyProtein)
                .keyboardType(.decimalPad)
            Button("确认并保存目标", systemImage: "checkmark.circle") {
                isConfirmingGoalSave = true
            }
            .confirmationDialog("确认保存健康目标？", isPresented: $isConfirmingGoalSave) {
                Button("确认并保存") {
                    saveGoalProfile()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("目标只用于本机健康摘要与趋势，不会单独上传；之后可随时修改。")
            }
            Text("目标是你设定的参考，不构成医疗建议。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var notificationSection: some View {
        Section("本地健康回顾提醒") {
            Toggle(
                "晨间回顾提醒",
                isOn: Binding(
                    get: { dependencies.briefNotificationScheduler.morningEnabled },
                    set: { setMorningNotification($0) }
                )
            )
            if dependencies.briefNotificationScheduler.morningEnabled {
                DatePicker(
                    "晨间提醒时间",
                    selection: reminderTimeBinding(
                        hour: dependencies.briefNotificationScheduler.morningHour,
                        minute: dependencies.briefNotificationScheduler.morningMinute,
                        onChange: setMorningNotificationTime
                    ),
                    displayedComponents: .hourAndMinute
                )
            }
            Toggle(
                "晚间回顾提醒",
                isOn: Binding(
                    get: { dependencies.briefNotificationScheduler.eveningEnabled },
                    set: { setEveningNotification($0) }
                )
            )
            if dependencies.briefNotificationScheduler.eveningEnabled {
                DatePicker(
                    "晚间提醒时间",
                    selection: reminderTimeBinding(
                        hour: dependencies.briefNotificationScheduler.eveningHour,
                        minute: dependencies.briefNotificationScheduler.eveningMinute,
                        onChange: setEveningNotificationTime
                    ),
                    displayedComponents: .hourAndMinute
                )
            }
            Toggle(
                "每周一 08:00 提醒查看周报",
                isOn: Binding(
                    get: { dependencies.briefNotificationScheduler.weeklyEnabled },
                    set: { setWeeklyNotification($0) }
                )
            )
            Text("晨间和晚间提醒默认时间为 08:00 和 21:00；提醒默认关闭，可随时调整或关闭。通知只使用本地健康摘要，不显示健康数值。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reminderTimeBinding(
        hour: Int,
        minute: Int,
        onChange: @escaping (Int, Int) -> Void
    ) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                guard let hour = components.hour, let minute = components.minute else { return }
                onChange(hour, minute)
            }
        )
    }

    private func loadGoalFields() async {
        do {
            guard let goal = try await dependencies.healthIntelligenceService.goalProfile() else { return }
            goalTargetWeight = goal.targetWeightKilograms.map { String($0) } ?? ""
            goalDailyDeficit = goal.dailyDeficitKcal.map(String.init) ?? ""
            goalDailyProtein = goal.dailyProteinGrams.map { String($0) } ?? ""
        } catch {
            healthAuthorizationError = "无法加载健康目标：\(safeErrorMessage(error))"
        }
    }

    private func saveGoalProfile() {
        Task {
            do {
                let targetWeight = try optionalNumber(goalTargetWeight, field: "目标体重", range: 25...350)
                let deficitValue = try optionalNumber(goalDailyDeficit, field: "每日缺口", range: 0...3_000)
                let protein = try optionalNumber(goalDailyProtein, field: "蛋白质目标", range: 0...500)
                let goal = GoalProfile(
                    effectiveFrom: Date(),
                    targetWeightKilograms: targetWeight,
                    dailyDeficitKcal: deficitValue.map { Int($0.rounded()) },
                    dailyProteinGrams: protein
                )
                try await dependencies.healthIntelligenceService.saveGoalProfile(goal)
                _ = try await dependencies.healthIntelligenceService.refresh()
                statusMessage = "健康目标已确认并保存。"
                healthAuthorizationError = nil
            } catch {
                healthAuthorizationError = "未保存健康目标：\(safeErrorMessage(error))"
            }
        }
    }

    private func optionalNumber(
        _ text: String,
        field: String,
        range: ClosedRange<Double>
    ) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), value.isFinite, range.contains(value) else {
            throw GoalInputError.invalid(field)
        }
        return value
    }

    private func setMorningNotification(_ enabled: Bool) {
        Task {
            do {
                try await dependencies.briefNotificationScheduler.setMorningEnabled(enabled)
                notificationError = nil
            } catch {
                notificationError = safeErrorMessage(error)
            }
        }
    }

    private func setEveningNotification(_ enabled: Bool) {
        Task {
            do {
                try await dependencies.briefNotificationScheduler.setEveningEnabled(enabled)
                notificationError = nil
            } catch {
                notificationError = safeErrorMessage(error)
            }
        }
    }

    private func setMorningNotificationTime(_ hour: Int, _ minute: Int) {
        Task {
            do {
                try await dependencies.briefNotificationScheduler.setMorningTime(hour: hour, minute: minute)
                notificationError = nil
            } catch {
                notificationError = safeErrorMessage(error)
            }
        }
    }

    private func setEveningNotificationTime(_ hour: Int, _ minute: Int) {
        Task {
            do {
                try await dependencies.briefNotificationScheduler.setEveningTime(hour: hour, minute: minute)
                notificationError = nil
            } catch {
                notificationError = safeErrorMessage(error)
            }
        }
    }

    private func setWeeklyNotification(_ enabled: Bool) {
        Task {
            do {
                try await dependencies.briefNotificationScheduler.setWeeklyEnabled(enabled)
                notificationError = nil
            } catch {
                notificationError = safeErrorMessage(error)
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
                    dependencies.healthKitService.hasRequestedAuthorization ? "同步 Apple Health" : "连接 Apple Health",
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
                    detail: "兼容 Speech 授权；设备不支持本地识别时可能使用 Apple 语音服务",
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

            Button("导出脱敏语音诊断", systemImage: "waveform.badge.magnifyingglass") {
                Task { await exportSpeechDiagnostics() }
            }

            Button("导出系统诊断 JSON", systemImage: "stethoscope") {
                Task { await exportDiagnostics() }
            }
            .disabled(isExportingDiagnostics)

            Text("仅包含版本、云端提供方与模型、延迟/用量/错误码、同步投影和 Watch 状态；不含健康记录、备注、转录、偏好、密钥或同意内容。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isExportingDiagnostics {
                ProgressView("正在生成脱敏诊断")
            }

            if dependencies.exportService.isExporting {
                ProgressView("正在生成备份")
            }
        }
    }

    private func saveDeepSeekKey() async {
        guard !apiKey.isEmpty else { return }
        do {
            try KeychainStore.shared.saveAPIKey(apiKey)
            apiKey = ""
            hasSavedAPIKey = true
            statusMessage = "API Key 已保存到 Keychain。"
        } catch {
            statusMessage = nil
            healthAuthorizationError = "无法保存 API Key：\(safeErrorMessage(error))"
        }
    }

    private func saveQwenKey() async {
        guard !qwenAPIKey.isEmpty else { return }
        do {
            try KeychainStore.shared.saveModelStudioAPIKey(qwenAPIKey)
            qwenAPIKey = ""
            hasSavedQwenAPIKey = true
            statusMessage = "Model Studio Key 已保存到 Keychain。"
        } catch {
            statusMessage = nil
            healthAuthorizationError = "无法保存 Model Studio Key：\(safeErrorMessage(error))"
        }
    }

    private func saveConsent(
        provider: ProviderID,
        dataClass: ProviderDataClass = .healthText,
        granted: Bool
    ) async {
        do {
            let policyVersion: String
            switch (provider, dataClass) {
            case (.qwen, .speechAudio): policyVersion = "qwen-single-audio-v1"
            case (.qwen, .mealImage): policyVersion = "qwen-sanitized-meal-image-v1"
            case (.deepSeek, .mealImage): policyVersion = "deepseek-sanitized-meal-image-v1"
            case (_, let value) where value.isHealthContextClass: policyVersion = "cloud-health-context-v1"
            default: policyVersion = "cloud-health-text-v1"
            }
            try await dependencies.providerGovernanceRepository.setConsent(
                provider: provider,
                dataClass: dataClass,
                granted: granted,
                policyVersion: policyVersion
            )
        } catch {
            healthAuthorizationError = "无法保存云端同意状态：\(safeErrorMessage(error))"
        }
    }

    private func refreshProviderGovernance() async {
        deepSeekTextConsent = (try? await dependencies.providerGovernanceRepository.isConsentGranted(
            provider: .deepSeek,
            dataClass: .healthText
        )) == true
        deepSeekMealImageConsent = (try? await dependencies.providerGovernanceRepository.isConsentGranted(
            provider: .deepSeek,
            dataClass: .mealImage
        )) == true
        qwenTextConsent = (try? await dependencies.providerGovernanceRepository.isConsentGranted(
            provider: .qwen,
            dataClass: .healthText
        )) == true
        qwenSpeechConsent = (try? await dependencies.providerGovernanceRepository.isConsentGranted(
            provider: .qwen,
            dataClass: .speechAudio
        )) == true
        qwenMealImageConsent = (try? await dependencies.providerGovernanceRepository.isConsentGranted(
            provider: .qwen,
            dataClass: .mealImage
        )) == true
        let deepSeekPolicy = try? await CloudHealthContextPolicy.load(
            from: dependencies.providerGovernanceRepository,
            provider: .deepSeek
        )
        let qwenPolicy = try? await CloudHealthContextPolicy.load(
            from: dependencies.providerGovernanceRepository,
            provider: .qwen
        )
        deepSeekHealthContextClasses = deepSeekPolicy?.allowedClasses ?? []
        deepSeekConversationHistoryConsent = deepSeekPolicy?.allowsConversationHistory == true
        qwenHealthContextClasses = qwenPolicy?.allowedClasses ?? []
        qwenConversationHistoryConsent = qwenPolicy?.allowsConversationHistory == true
        deepSeekUsage = await usageText(provider: .deepSeek)
        qwenUsage = await usageText(provider: .qwen)
    }

    @ViewBuilder
    private func healthContextConsentControls(
        provider: ProviderID,
        selection: Binding<Set<ProviderDataClass>>
    ) -> some View {
        ForEach(CloudHealthContextPolicy.dataClasses, id: \.self) { dataClass in
            Toggle(
                "允许上传\(dataClass.healthContextTitle ?? "健康")历史汇总",
                isOn: Binding(
                    get: { selection.wrappedValue.contains(dataClass) },
                    set: { granted in
                        var updated = selection.wrappedValue
                        if granted {
                            pendingCloudPolicyExpansion = .health(PendingHealthPolicyExpansion(
                                provider: provider,
                                dataClass: dataClass
                            ))
                            isConfirmingCloudPolicyExpansion = true
                        } else {
                            updated.remove(dataClass)
                            selection.wrappedValue = updated
                            Task {
                                await saveHealthContextPolicy(
                                    provider: provider,
                                    allowedClasses: updated,
                                    source: .settings
                                )
                            }
                        }
                    }
                )
            )
        }
    }

    private func confirmHealthPolicyExpansion(_ pending: PendingHealthPolicyExpansion) async {
        var updated = pending.provider == .deepSeek
            ? deepSeekHealthContextClasses
            : qwenHealthContextClasses
        updated.insert(pending.dataClass)
        await saveHealthContextPolicy(
            provider: pending.provider,
            allowedClasses: updated,
            source: .settings,
            confirmedAt: Date()
        )
        pendingCloudPolicyExpansion = nil
    }

    private func saveHealthContextPolicy(
        provider: ProviderID,
        allowedClasses: Set<ProviderDataClass>,
        source: CloudHealthPolicyChangeSource,
        confirmedAt: Date? = nil
    ) async {
        do {
            if let confirmedAt {
                _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
                    provider: provider,
                    allowedClasses: allowedClasses,
                    repository: dependencies.providerGovernanceRepository,
                    confirmedAt: confirmedAt,
                    changeSource: source
                )
            } else {
                _ = try await CloudHealthContextPolicy.applyRestrictiveChange(
                    provider: provider,
                    allowedClasses: allowedClasses,
                    repository: dependencies.providerGovernanceRepository,
                    changeSource: source
                )
            }
            if provider == .deepSeek {
                deepSeekHealthContextClasses = allowedClasses
            } else {
                qwenHealthContextClasses = allowedClasses
            }
        } catch {
            healthAuthorizationError = "无法保存云端健康授权策略：\(safeErrorMessage(error))"
            await refreshProviderGovernance()
        }
    }

    @ViewBuilder
    private func conversationHistoryConsentControl(
        provider: ProviderID,
        selection: Binding<Bool>
    ) -> some View {
        Toggle(
            "允许向\(provider == .deepSeek ? "DeepSeek" : "Qwen")发送此前聊天记录",
            isOn: Binding(
                get: { selection.wrappedValue },
                set: { granted in
                    if granted {
                        pendingCloudPolicyExpansion = .conversationHistory(provider)
                        isConfirmingCloudPolicyExpansion = true
                    } else {
                        selection.wrappedValue = false
                        Task {
                            await saveConversationHistoryConsent(provider: provider, granted: false)
                        }
                    }
                }
            )
        )
    }

    private func saveConversationHistoryConsent(
        provider: ProviderID,
        granted: Bool,
        confirmedAt: Date? = nil
    ) async {
        do {
            _ = try await CloudHealthContextPolicy.updateConversationHistoryConsent(
                provider: provider,
                allowed: granted,
                repository: dependencies.providerGovernanceRepository,
                confirmedAt: confirmedAt,
                changeSource: .settings
            )
            if provider == .deepSeek {
                deepSeekConversationHistoryConsent = granted
            } else {
                qwenConversationHistoryConsent = granted
            }
            pendingCloudPolicyExpansion = nil
        } catch {
            healthAuthorizationError = "无法保存聊天记录云端授权：\(safeErrorMessage(error))"
            await refreshProviderGovernance()
        }
    }

    private func usageText(provider: ProviderID) async -> String {
        guard let summary = try? await dependencies.providerUsageLedger.monthlySummary(provider: provider) else {
            return "暂不可用"
        }
        let tokens = summary.inputTokens + summary.outputTokens
        let audio = summary.audioSeconds > 0
            ? " · \(summary.audioSeconds.formatted(.number.precision(.fractionLength(0...1)))) 秒音频"
            : ""
        let images = summary.imageCount > 0 ? " · \(summary.imageCount) 张图" : ""
        let latency = summary.averageLatencyMilliseconds.map { " · 平均 \($0) ms" } ?? ""
        guard let cost = summary.estimatedCostMicros, let currency = summary.currency else {
            return "\(tokens) tokens\(images)\(audio)\(latency) · 费用暂不可估"
        }
        return "\(tokens) tokens\(images)\(audio)\(latency) · 保守估算 \(String(format: "%.2f", Double(cost) / 1_000_000)) \(currency)"
    }

    private func exportData() async {
        do {
            let url = try await dependencies.exportService.exportJSON(context: modelContext)
            exportURL = url
            showShareSheet = true
        } catch {
            dependencies.exportService.lastError = safeErrorMessage(error)
        }
    }

    private func exportSpeechDiagnostics() async {
        do {
            exportURL = try await dependencies.speechService.exportDiagnostics()
            showShareSheet = true
        } catch {
            healthAuthorizationError = "无法导出语音诊断：\(safeErrorMessage(error))"
        }
    }

    private func exportDiagnostics() async {
        isExportingDiagnostics = true
        defer { isExportingDiagnostics = false }
        await Task.yield()
        let watch = dependencies.watchConnectivityCoordinator
        do {
            exportURL = try dependencies.diagnosticsExportService.exportJSON(
                context: modelContext,
                mode: dependencies.intelligencePreferences.mode,
                watch: DiagnosticsWatchStatus(
                    isAvailable: watch.isAvailable,
                    isActivated: watch.isActivated,
                    hasError: watch.lastError != nil
                ),
                dailyLoop: DiagnosticsDailyLoopStatus(
                    lastGeneratedAt: dependencies.dailyLoopSnapshotService.lastGeneratedAt,
                    nextRefreshEarliestAt: dependencies.dailyLoopBackgroundScheduler.nextRefreshEarliestAt
                )
            )
            healthAuthorizationError = nil
            showShareSheet = true
        } catch {
            healthAuthorizationError = "无法生成系统诊断文件，请稍后重试。"
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
            dependencies.dailyLoopBackgroundScheduler.scheduleNextRefresh()
            let healthRepository = HealthRepository(modelContext: modelContext)
            let backgroundDeliveryEnabled = try await dependencies.healthKitSyncCoordinator
                .startBackgroundObservers(using: healthRepository)
            let syncResult = try await dependencies.healthKitSyncCoordinator.syncAvailableData(
                using: healthRepository,
                forceRebaseline: true
            )
            await dependencies.healthSyncOutboxWorker.processPending(in: modelContext)
            if syncResult.hasFailures {
                statusMessage = "HealthKit 已部分同步；失败流的未完成页不前移游标，其他数据仍已更新。读取范围由系统保护，无数据不代表已拒绝授权。"
            } else {
                statusMessage = backgroundDeliveryEnabled
                    ? "已完成本次 HealthKit 同步；读取范围由系统保护，无数据不代表已拒绝授权。"
                    : "前台同步已完成；系统未确认后台投递可用（可能受签名 entitlement 限制）。读取范围由系统保护，无数据不代表已拒绝授权。"
            }
            await refreshDiagnostics()
        } catch {
            let errorMessage = SharedErrorDescriptor.mapped(
                from: error,
                fallback: .healthKitUnavailableFallback
            ).userMessage
            healthAuthorizationError = "Apple Health 授权失败：\(errorMessage)"
            await refreshDiagnostics()
        }
    }
}

private func safeErrorMessage(
    _ error: Error,
    fallback: SharedErrorDescriptor = .actionConflictFallback
) -> String {
    SharedErrorDescriptor.mapped(from: error, fallback: fallback).userMessage
}

private enum GoalInputError: SharedErrorDescribing {
    case invalid(String)

    var sharedErrorDescriptor: SharedErrorDescriptor {
        switch self {
        case .invalid(let field):
            SharedErrorDescriptor(
                code: .toolArgumentsInvalid,
                userMessage: "\(field)格式无效或超出允许范围。",
                subsystem: .confirmation,
                reason: .invalidToolArguments
            )
        }
    }

    var errorDescription: String? { sharedErrorDescriptor.userMessage }
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
    @State private var dateOfBirth: Date?
    @State private var dateOfBirthDraft: Date
    @State private var hasEditedDateOfBirth = false
    @State private var showingDateOfBirthPicker = false
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
        _dateOfBirthDraft = State(
            initialValue: profile.dateOfBirth
                ?? Calendar.current.date(byAdding: .year, value: -30, to: Date())
                ?? Date()
        )
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
                        Button {
                            dateOfBirthDraft = dateOfBirth
                                ?? (Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date())
                            hasEditedDateOfBirth = false
                            showingDateOfBirthPicker = true
                        } label: {
                            LabeledContent(
                                "出生日期",
                                value: dateOfBirth?.formatted(date: .abbreviated, time: .omitted) ?? "未填写"
                            )
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
            .sheet(isPresented: $showingDateOfBirthPicker) {
                NavigationStack {
                    Form {
                        DatePicker(
                            "出生日期",
                            selection: $dateOfBirthDraft,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        Button("清除出生日期", role: .destructive) {
                            dateOfBirth = nil
                            showingDateOfBirthPicker = false
                        }
                    }
                    .navigationTitle("选择出生日期")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showingDateOfBirthPicker = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                dateOfBirth = dateOfBirthDraft
                                showingDateOfBirthPicker = false
                            }
                            .disabled(!hasEditedDateOfBirth)
                        }
                    }
                    .onChange(of: dateOfBirthDraft) { _, _ in
                        hasEditedDateOfBirth = true
                    }
                }
            }
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

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let weightChanged = abs(profile.weightKg - weightValue) > 0.001
        let revisionChanged = profile.name != trimmedName
            || profile.biologicalSex != sex
            || profile.dateOfBirth != dateOfBirth
            || abs(profile.heightCm - heightValue) > 0.001
            || weightChanged
            || profile.activityLevel != activity
            || profile.dailyDeficitTarget != targetValue

        profile.name = trimmedName
        profile.biologicalSex = sex
        profile.dateOfBirth = dateOfBirth
        profile.profileNeedsCompletion = dateOfBirth == nil
        profile.heightCm = heightValue
        profile.weightKg = weightValue
        profile.activityLevel = activity
        profile.dailyDeficitTarget = targetValue
        profile.updatedAt = now

        if revisionChanged {
            modelContext.insert(
                ProfileRevisionRecord(
                    profileKey: profile.profileKey,
                    effectiveFrom: now,
                    dateOfBirth: dateOfBirth,
                    biologicalSex: sex,
                    heightCm: heightValue,
                    weightKg: weightValue,
                    activityLevel: activity,
                    source: "userEdited",
                    createdAt: now
                )
            )
        }

        do {
            if weightChanged {
                try HealthRepository(modelContext: modelContext).insert(
                    WeightRecord(
                        sourceActionKey: "settings-weight-\(UUID().uuidString.lowercased())",
                        measuredAt: now,
                        kilograms: weightValue,
                        source: "manual",
                        algorithmVersion: "weight-v2",
                        confidence: 0.9
                    )
                )
            } else {
                try DailyMetricsProjector.reproject(on: now, in: modelContext)
                try modelContext.save()
            }
            dismiss()
        } catch {
            validationError = "保存失败：\(safeErrorMessage(error))"
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
    let persistence = PersistenceBootstrap.make(inMemory: true)
    SettingsScreen()
        .modelContainer(persistence.container)
        .environment(Dependencies(modelContainer: persistence.container))
}
