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
    @State private var loadError: String?

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

                    if let metrics {
                        todayCard(metrics)
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
                    } else {
                        ContentUnavailableView(
                            "七日趋势等待数据",
                            systemImage: "calendar.badge.clock",
                            description: Text("记录会按自然日聚合；空白日期不会被补成虚假数据。")
                        )
                        .orbitCard()
                    }

                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
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
                // Clear this view's value-type snapshot synchronously when the
                // app foregrounds; AppRoot then purges the HealthKit window.
                weekly = nil
                if dependencies.healthKitService.hasRequestedAuthorization {
                    healthSnapshotStatus = "最近 42 天的健康数据正在重新验证；旧趋势已隐藏。"
                }
                Task { await loadData() }
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
        let balanceValue = deficit.map { "\(deficitPrefix)\(String(format: "%.0f", $0))" } ?? "暂无"
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("今日热量")
                    .font(.headline)
                Spacer()
                OrbitStatusBadge(text: "今天", tone: .blue)
            }

            HStack(spacing: 12) {
                OrbitMetric(value: intakeValue, label: "摄入 kcal")
                OrbitMetric(value: expenditureValue, label: "消耗 kcal")
                OrbitMetric(
                    value: balanceValue,
                    label: "缺口 kcal",
                    tint: deficit != nil
                        ? ((deficit ?? 0) >= 0 ? OrbitPalette.green : OrbitPalette.coral)
                        : Color.gray
                )
            }

            if let expenditure, let intake, expenditure > 0 {
                ProgressView(
                    value: max(intake, 0),
                    total: expenditure
                )
                .tint(OrbitPalette.blue)
                .accessibilityLabel("今日摄入占总消耗")
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
        loadError = nil
        weekly = nil
        if dependencies.healthContextExportGate.isOpen {
            do {
                _ = try await dependencies.healthIntelligenceService.refresh()
            } catch {
                loadError = SharedErrorDescriptor.mapped(
                    from: error,
                    fallback: .projectionFailedFallback
                ).userMessage
            }
        }
        await loadWeeklyProjection()
    }

    private func loadWeeklyProjection() async {
        weekly = nil
        do {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let predicate = #Predicate<DailyMetrics> { $0.date == today }
            metrics = try modelContext.fetch(FetchDescriptor<DailyMetrics>(predicate: predicate)).first
            guard dependencies.healthContextExportGate.isOpen else {
                weekly = nil
                healthSnapshotStatus = "健康数据缓存尚未完成安全清理，趋势暂不可用；手工记录仍保留。"
                return
            }
            let goal = try await dependencies.healthIntelligenceService.goalProfile(asOf: today)
            guard dependencies.healthContextExportGate.isOpen else {
                weekly = nil
                healthSnapshotStatus = "健康数据缓存尚未完成安全清理，趋势暂不可用；手工记录仍保留。"
                return
            }
            weekly = try WeeklyAnalyticsService(calendar: calendar).load(
                referenceDate: today,
                profile: profiles.first,
                goal: goal,
                in: modelContext
            )
            healthSnapshotStatus = nil
        } catch {
            loadError = SharedErrorDescriptor.mapped(
                from: error,
                fallback: .projectionFailedFallback
            ).userMessage
        }
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
