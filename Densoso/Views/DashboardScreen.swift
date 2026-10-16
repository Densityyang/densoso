import Charts
import DensosoDomain
import SwiftData
import SwiftUI

struct DashboardScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Dependencies.self) private var dependencies
    @Query private var profiles: [UserProfile]

    @State private var metrics: DailyMetrics?
    @State private var weekly: WeeklyAnalyticsSnapshot?
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

                    if let weekly, weekly.hasData {
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
                }
                .padding()
            }
            .refreshable { loadData() }
            .navigationTitle("趋势")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: loadData)
        }
    }

    private func todayCard(_ metrics: DailyMetrics) -> some View {
        let hasEnergyEstimate = metrics.energyQuality != "unavailable" && !metrics.requiresRecompute
        let energyPrefix = metrics.energyQuality == "estimated" ? "约 " : ""
        let intakeValue = metrics.mealCount == 0 ? "未记录" : "\(metrics.totalIntakeKcal)"
        let expenditureValue = hasEnergyEstimate ? "\(energyPrefix)\(metrics.totalExpenditureKcal)" : "暂无"
        let balanceValue = hasEnergyEstimate ? "\(energyPrefix)\(metrics.deficitKcal)" : "暂无"
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
                    tint: hasEnergyEstimate
                        ? (metrics.deficitKcal >= 0 ? OrbitPalette.green : OrbitPalette.coral)
                        : Color.gray
                )
            }

            if hasEnergyEstimate, metrics.totalExpenditureKcal > 0 {
                ProgressView(
                    value: Double(max(metrics.totalIntakeKcal, 0)),
                    total: Double(metrics.totalExpenditureKcal)
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
                    Text("\(weekly.recordedDays) 天有记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                OrbitStatusBadge(text: "总缺口 \(weekly.totalDeficitKcal)", tone: .gold)
            }

            Chart {
                ForEach(weekly.points) { point in
                    BarMark(
                        x: .value("日期", point.date, unit: .day),
                        y: .value("实际缺口", point.deficitKcal)
                    )
                    .foregroundStyle(
                        point.hasData ? OrbitPalette.blue.gradient : Color(.quaternarySystemFill).gradient
                    )
                    .cornerRadius(4)
                }

                if let target = weekly.points.first?.targetDeficitKcal {
                    RuleMark(y: .value("每日目标", target))
                        .foregroundStyle(OrbitPalette.gold)
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
            .accessibilityLabel("过去七天实际热量缺口与每日目标")

            HStack(spacing: 12) {
                OrbitMetric(
                    value: String(format: "%.0f", weekly.averageDailyDeficitKcal),
                    label: "记录日均缺口"
                )
                OrbitMetric(
                    value: String(format: "%.2f", weekly.projectedWeightLossKg),
                    label: "按当前七日缺口折算 kg",
                    tint: OrbitPalette.green
                )
            }

            HStack(spacing: 16) {
                Label("实际缺口", systemImage: "square.fill")
                    .foregroundStyle(OrbitPalette.blue)
                Label("每日目标", systemImage: "line.diagonal")
                    .foregroundStyle(OrbitPalette.gold)
            }
            .font(.caption)
        }
        .orbitCard()
    }

    private func loadData() {
        loadError = nil
        do {
            _ = try dependencies.healthIntelligenceService.refresh()
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let predicate = #Predicate<DailyMetrics> { $0.date == today }
            metrics = try modelContext.fetch(FetchDescriptor<DailyMetrics>(predicate: predicate)).first
            weekly = try WeeklyAnalyticsService(calendar: calendar).load(
                referenceDate: today,
                profile: profiles.first,
                goal: try dependencies.healthIntelligenceService.goalProfile(asOf: today),
                in: modelContext
            )
        } catch {
            loadError = "无法更新数据看板：\(error.localizedDescription)"
        }
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
        case .learning: "学习中"
        case .withinTypicalRange: "处于个人范围"
        case .changed: "与近期不同"
        case .attention: "值得留意"
        }
    }

    private func statusColor(_ status: HealthDomainStatus) -> Color {
        switch status {
        case .noData: Color.secondary
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
