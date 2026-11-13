import Charts
import DensosoDomain
import SwiftData
import SwiftUI

struct DashboardScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Dependencies.self) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @Query private var profiles: [UserProfile]

    @State private var metrics: DailyMetrics?
    @State private var weekly: WeeklyAnalyticsSnapshot?
    @State private var healthSnapshotStatus: String?
    @State private var healthRefreshError: String?
    @State private var projectionReadError: String?
    @State private var nutritionRecordActionError: String?
    @State private var isLoadingProjection = true
    @State private var projectionLoadGeneration = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    OrbitScreenHeader(
                        eyebrow: "Trends without a health score",
                        title: "看见自己的长期节奏",
                        subtitle: "数据只和个人基线比较；缺失值保留为空，不生成统一健康分。"
                    )

                    if let brief = dependencies.healthIntelligenceService.dailyBrief {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("四域状态")
                                .font(.headline)
                            ForEach(brief.domains) { domain in
                                HStack {
                                    Text(domainLabel(domain.domain))
                                    Spacer()
                                    Text(statusLabel(domain.status))
                                        .foregroundStyle(statusColor(domain.status))
                                    if let value = domain.currentValue {
                                        Text(value.formatted(.number.precision(.fractionLength(0))))
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.subheadline)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .orbitCard()
                    }

                    WeeklyHealthBriefCard(brief: dependencies.healthIntelligenceService.weeklyBrief)

                    if let brief = dependencies.healthIntelligenceService.dailyBrief {
                        HealthVitalTrendsCard(trends: brief.vitalTrends)
                    }

                    NavigationLink {
                        WorkoutPlanScreen()
                    } label: {
                        Label("查看训练计划", systemImage: "figure.run")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .orbitCard()

                    if isLoadingProjection, (metrics != nil || weekly != nil) {
                        Label("正在刷新；暂时显示上次读取的数据", systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .orbitCard()
                    }

                    if let metrics {
                        todayCard(metrics)
                    } else if isLoadingProjection {
                        ProgressView("正在读取今日指标")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .orbitCard()
                    } else if projectionReadError != nil {
                        ContentUnavailableView(
                            "今日数据暂不可用",
                            systemImage: "exclamationmark.triangle",
                            description: Text("读取失败；刷新后重试。")
                        )
                        .orbitCard()
                    } else {
                        ContentUnavailableView(
                            "今日暂无记录",
                            systemImage: "chart.bar",
                            description: Text("去对话页记一餐或一次运动后，这里会自动更新。")
                        )
                        .orbitCard()
                    }

                    if let weekly, weekly.hasData, weekly.totalDeficitKcal != nil {
                        weeklyCard(weekly)
                    } else if isLoadingProjection {
                        ProgressView("正在读取七日趋势")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .orbitCard()
                    } else if projectionReadError != nil {
                        ContentUnavailableView(
                            "趋势暂不可用",
                            systemImage: "exclamationmark.triangle",
                            description: Text("读取失败；刷新后重试。")
                        )
                        .orbitCard()
                    } else {
                        ContentUnavailableView(
                            "七日趋势等待数据",
                            systemImage: "calendar.badge.clock",
                            description: Text("记录会按自然日聚合；空白日期不会被补成虚假数据。")
                        )
                        .orbitCard()
                    }

                    if let projectionReadError, (metrics != nil || weekly != nil) {
                        Label("显示上次读取的数据，可能已过时：\(projectionReadError)", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(OrbitPalette.coral)
                            .orbitCard()
                    }
                    if let healthRefreshError {
                        Label("健康数据刷新失败；趋势保留上次成功读取的内容：\(healthRefreshError)", systemImage: "heart.text.square")
                            .font(.footnote)
                            .foregroundStyle(OrbitPalette.coral)
                            .orbitCard()
                    }
                    if let healthSnapshotStatus {
                        Label(healthSnapshotStatus, systemImage: "heart.text.square")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .orbitCard()
                    }
                }
                .padding()
            }
            .refreshable { await loadData() }
            .navigationTitle("趋势")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadData() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                // Re-read persisted projections when returning to the foreground.
                if dependencies.healthKitService.hasRequestedAuthorization {
                    healthSnapshotStatus = "正在重新验证健康摘要；读取完成前会保留上次成功数据并标记刷新状态。"
                }
                Task { await loadData() }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: ModelContext.didSave)
                    .receive(on: DispatchQueue.main)
            ) { notification in
                guard Self.containsDashboardProjectionChanges(notification) else { return }
                Task { await loadWeeklyProjection() }
            }
            .onChange(of: dependencies.healthIntelligenceService.weeklyBrief) { _, _ in
                Task { await loadWeeklyProjection() }
            }
        }
    }

    private func todayCard(_ metrics: DailyMetrics) -> some View {
        let result = DailyMetricsReadModelMapper.make(metrics)
        let expenditure = result.expenditure.value?.likely
        let intake = result.intake.value?.likely
        let deficit = result.deficit.value?.likely
        let hasEnergyEstimate = expenditure != nil
        let intakePrefix = approximatePrefix(for: result.intake.availability)
        let expenditurePrefix = approximatePrefix(for: result.expenditure.availability)
        let deficitPrefix = approximatePrefix(for: result.deficit.availability)
        let intakeValue = intake.map { "\(intakePrefix)\(String(format: "%.0f", $0))" }
            ?? (metrics.mealCount == 0 ? "未记录" : "暂无")
        let expenditureValue = expenditure.map { "\(expenditurePrefix)\(String(format: "%.0f", $0))" } ?? "暂无"
        let hasCompleteIntake = result.hasCompleteDailyIntakeEstimate
        let balanceValue = hasCompleteIntake
            ? (deficit.map { "\(deficitPrefix)\(String(format: "%.0f", $0))" } ?? "暂无")
            : (result.nutritionRecordStatus == .complete ? "待估算" : "待确认")
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("今日热量")
                    .font(.headline)
                Spacer()
                OrbitStatusBadge(text: "今天", tone: .blue)
            }

            HStack(spacing: 12) {
                OrbitMetric(
                    value: intakeValue,
                    label: hasCompleteIntake
                        ? "全天摄入 kcal"
                        : (intake == nil ? "已记录 kcal" : "已估算摄入 kcal")
                )
                OrbitMetric(value: expenditureValue, label: "消耗 kcal")
                OrbitMetric(
                    value: balanceValue,
                    label: hasCompleteIntake
                        ? "全天缺口 kcal"
                        : (result.nutritionRecordStatus == .complete ? "缺口待估算" : "缺口待确认"),
                    tint: deficit != nil
                        ? ((deficit ?? 0) >= 0 ? OrbitPalette.green : OrbitPalette.coral)
                        : Color.gray
                )
            }

            if hasCompleteIntake,
               let expenditure, let intake, expenditure > 0 {
                ProgressView(
                    value: max(intake, 0),
                    total: expenditure
                )
                .tint(OrbitPalette.blue)
                .accessibilityLabel("今日摄入占总消耗")
            }
            Text(nutritionRecordStatusDescription(result.nutritionRecordStatus))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                let targetStatus: NutritionDayRecordStatus = result.nutritionRecordStatus == .complete
                    ? (metrics.mealCount == 0 ? .unknown : .inProgress)
                    : .complete
                Task {
                    await updateNutritionRecordStatus(targetStatus, for: metrics)
                }
            } label: {
                Label(
                    result.nutritionRecordStatus == .complete
                        ? "撤销完整确认"
                        : "确认今天饮食记录完整",
                    systemImage: result.nutritionRecordStatus == .complete
                        ? "arrow.uturn.backward"
                        : "checkmark.circle"
                )
            }
            .disabled(
                metrics.requiresRecompute
                    || (result.nutritionRecordStatus != .complete
                        && !DailyMetricsReadModelMapper.hasNutritionMealFingerprint(for: metrics))
            )
            .font(.subheadline)
            if let nutritionRecordActionError {
                Text(nutritionRecordActionError)
                    .font(.footnote)
                    .foregroundStyle(OrbitPalette.coral)
            }
            if !hasEnergyEstimate {
                Text("个人资料或健康数据还不完整，暂时无法估算今日消耗。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if metrics.energyQuality == "estimated" {
                Text("消耗根据个人资料估算。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .orbitCard(emphasized: true)
    }

    private func updateNutritionRecordStatus(
        _ status: NutritionDayRecordStatus,
        for metric: DailyMetrics
    ) async {
        do {
            let operationBarrier = PersistenceOperationBarrier.shared
            let operationLease = try await operationBarrier.acquireMutationOperation()
            defer { operationBarrier.release(operationLease) }
            try await operationBarrier.withLease(operationLease) {
                try await DailyMetricsProjectionWriteGate.withLock(for: modelContext) {
                    guard !metric.requiresRecompute else {
                        nutritionRecordActionError = "今日投影正在刷新，完成后再更新饮食记录状态。"
                        return
                    }
                    guard DailyMetricsReadModelMapper.setNutritionDayRecordStatus(status, for: metric) else {
                        nutritionRecordActionError = "今日饮食记录尚未完成投影，请刷新后重试。"
                        return
                    }
                    do {
                        try modelContext.save()
                        nutritionRecordActionError = nil
                    } catch {
                        modelContext.rollback()
                        throw error
                    }
                }
            }
            if nutritionRecordActionError == nil {
                await loadData()
            }
        } catch {
            nutritionRecordActionError = SharedErrorDescriptor.mapped(
                from: error,
                fallback: .projectionFailedFallback
            ).userMessage
        }
    }

    private func nutritionRecordStatusDescription(_ status: NutritionDayRecordStatus) -> String {
        switch status {
        case .complete:
            "你已确认当天饮食记录完整。"
        case .inProgress:
            "当前摄入只是已记录餐食的汇总；当天记录尚未确认完整。"
        case .unknown:
            "当天饮食记录完整度未知；现有估值只代表已记录内容。"
        }
    }

    private func weeklyCard(_ weekly: WeeklyAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("过去 7 天")
                        .font(.headline)
                    Text("\(weekly.recordedDays) / 7 天有有效缺口数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                OrbitStatusBadge(
                    text: weekly.totalDeficitKcal.map {
                        "总缺口 \(approximatePrefix(for: weekly.deficitAvailability))\($0)"
                    } ?? "缺口数据不足",
                    tone: .gold
                )
            }

            Chart {
                ForEach(weekly.points.filter { $0.deficitKcal != nil }) { point in
                    if let deficit = point.deficitKcal {
                        BarMark(
                            x: .value("日期", point.date, unit: .day),
                            y: .value("能量缺口", deficit)
                        )
                        .foregroundStyle(
                            point.deficit.availability == .observed
                                ? OrbitPalette.blue.gradient
                                : OrbitPalette.gold.gradient
                        )
                        .cornerRadius(4)
                    }
                }

                if let target = weekly.points.first?.targetDeficitKcal {
                    RuleMark(y: .value("每日目标", target))
                        .foregroundStyle(OrbitPalette.coral)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }
            .frame(height: 180)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                    AxisTick()
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .accessibilityLabel("过去七天观察值或估算热量缺口与每日目标")

            HStack(spacing: 12) {
                OrbitMetric(
                    value: weekly.averageDailyDeficitKcal.map {
                        "\(approximatePrefix(for: weekly.deficitAvailability))\(String(format: "%.0f", $0))"
                    } ?? "暂无",
                    label: "记录日均缺口"
                )
                OrbitMetric(
                    value: weekly.projectedWeightLossKg.map { String(format: "%.1f", $0) } ?? "暂无",
                    label: "能量粗略折算（非体重预测）kg"
                )
            }

            HStack(spacing: 16) {
                Label("观察值缺口", systemImage: "square.fill")
                    .foregroundStyle(OrbitPalette.blue)
                Label("估算/部分缺口", systemImage: "square.fill")
                    .foregroundStyle(OrbitPalette.gold)
                Label("每日目标", systemImage: "line.diagonal")
                    .foregroundStyle(OrbitPalette.coral)
            }
            .font(.caption)
        }
        .orbitCard()
    }

    private func loadData() async {
        healthRefreshError = nil
        if dependencies.healthContextExportGate.isOpen {
            do {
                _ = try await dependencies.healthIntelligenceService.refresh()
            } catch {
                healthRefreshError = SharedErrorDescriptor.mapped(
                    from: error,
                    fallback: .projectionFailedFallback
                ).userMessage
            }
        }
        await loadWeeklyProjection()
    }

    private func loadWeeklyProjection() async {
        projectionLoadGeneration &+= 1
        let generation = projectionLoadGeneration
        isLoadingProjection = true
        defer {
            if projectionLoadGeneration == generation { isLoadingProjection = false }
        }
        do {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let predicate = #Predicate<DailyMetrics> { $0.date == today }
            metrics = try modelContext.fetch(FetchDescriptor<DailyMetrics>(predicate: predicate)).first
            guard projectionLoadGeneration == generation else { return }
            projectionReadError = nil
            guard dependencies.healthContextExportGate.isOpen else {
                weekly = nil
                healthSnapshotStatus = "健康数据缓存尚未完成安全清理，趋势暂不可用；手工记录仍保留。"
                return
            }
            let goal = try await dependencies.healthIntelligenceService.goalProfile(asOf: today)
            guard projectionLoadGeneration == generation else { return }
            guard dependencies.healthContextExportGate.isOpen else {
                weekly = nil
                healthSnapshotStatus = "健康数据缓存尚未完成安全清理，趋势暂不可用；手工记录仍保留。"
                return
            }
            weekly = try await WeeklyAnalyticsService(calendar: calendar).load(
                referenceDate: today,
                profile: profiles.first,
                goal: goal,
                in: modelContext
            )
            guard projectionLoadGeneration == generation else { return }
            projectionReadError = nil
            healthSnapshotStatus = nil
        } catch {
            guard projectionLoadGeneration == generation else { return }
            projectionReadError = SharedErrorDescriptor.mapped(
                from: error,
                fallback: .projectionFailedFallback
            ).userMessage
        }
    }

    static func containsDashboardProjectionChanges(_ notification: Notification) -> Bool {
        if notification.userInfo?[ModelContext.NotificationKey.invalidatedAllIdentifiers] != nil { return true }
        let keys: [ModelContext.NotificationKey] = [
            .insertedIdentifiers,
            .updatedIdentifiers,
            .deletedIdentifiers,
            .invalidatedAllIdentifiers,
        ]
        let relevantTypes: Set<String> = [
            Schema.entityName(for: DailyMetrics.self),
            Schema.entityName(for: MealRecord.self),
            Schema.entityName(for: WorkoutRecord.self),
            Schema.entityName(for: WeightRecord.self),
            Schema.entityName(for: DailyHealthSnapshotRecord.self),
            Schema.entityName(for: UserProfile.self),
            Schema.entityName(for: ProfileRevisionRecord.self),
            Schema.entityName(for: GoalProfileRecord.self),
        ]
        for key in keys {
            guard let identifiers = notification.userInfo?[key] as? Set<PersistentIdentifier> else { continue }
            if identifiers.contains(where: { relevantTypes.contains($0.entityName) }) { return true }
        }
        return false
    }

    private func approximatePrefix(for availability: MetricAvailability) -> String {
        availability == .observed ? "" : "约 "
    }

    private func domainLabel(_ domain: HealthDomain) -> String {
        switch domain {
        case .nutrition: "营养"
        case .sleep: "睡眠"
        case .activity: "活动"
        case .body: "身体指标"
        }
    }

    private func statusLabel(_ status: HealthDomainStatus) -> String {
        switch status {
        case .noData: "暂无数据"
        case .unknown: "数据覆盖未知"
        case .partial: "部分数据"
        case .learning: "学习中"
        case .withinTypicalRange: "处于个人范围"
        case .changed: "与近期不同"
        case .attention: "值得留意"
        }
    }

    private func statusColor(_ status: HealthDomainStatus) -> Color {
        switch status {
        case .noData: Color.secondary
        case .unknown: Color.secondary
        case .partial: OrbitPalette.blue
        case .learning: OrbitPalette.blue
        case .withinTypicalRange: OrbitPalette.green
        case .changed: OrbitPalette.gold
        case .attention: OrbitPalette.coral
        }
    }
}

#Preview {
    DashboardScreen()
        .modelContainer(for: [UserProfile.self, DailyMetrics.self, WeeklyReport.self], inMemory: true)
        .environment(Dependencies())
}
