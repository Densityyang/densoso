import Charts
import SwiftData
import SwiftUI

struct DashboardScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]

    @State private var metrics: DailyMetrics?
    @State private var weekly: WeeklyAnalyticsSnapshot?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    OrbitScreenHeader(
                        eyebrow: "From records to rhythm",
                        title: "今天的能量轨迹",
                        subtitle: "先看今天，再用七日趋势判断节奏。没有记录的日期会明确留空。"
                    )

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
            .navigationTitle("数据")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: loadData)
        }
    }

    private func todayCard(_ metrics: DailyMetrics) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("今日热量")
                    .font(.headline)
                Spacer()
                OrbitStatusBadge(text: "今天", tone: .blue)
            }

            HStack(spacing: 12) {
                OrbitMetric(value: "\(metrics.totalIntakeKcal)", label: "摄入 kcal")
                OrbitMetric(value: "\(metrics.totalExpenditureKcal)", label: "消耗 kcal")
                OrbitMetric(
                    value: "\(metrics.deficitKcal)",
                    label: "缺口 kcal",
                    tint: metrics.deficitKcal >= 0 ? OrbitPalette.green : OrbitPalette.coral
                )
            }

            if metrics.totalExpenditureKcal > 0 {
                ProgressView(
                    value: Double(max(metrics.totalIntakeKcal, 0)),
                    total: Double(metrics.totalExpenditureKcal)
                )
                .tint(OrbitPalette.blue)
                .accessibilityLabel("今日摄入占总消耗")
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
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let predicate = #Predicate<DailyMetrics> { $0.date == today }
            metrics = try modelContext.fetch(FetchDescriptor<DailyMetrics>(predicate: predicate)).first
            weekly = try WeeklyAnalyticsService(calendar: calendar).load(
                referenceDate: today,
                profile: profiles.first,
                in: modelContext
            )
        } catch {
            loadError = "无法更新数据看板：\(error.localizedDescription)"
        }
    }
}

#Preview {
    DashboardScreen()
        .modelContainer(for: [UserProfile.self, DailyMetrics.self, WeeklyReport.self], inMemory: true)
}
