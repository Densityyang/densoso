import SwiftUI
import SwiftData

struct DashboardScreen: View {
    @Environment(\.modelContext) private var modelContext
    @State private var metrics: DailyMetrics?
    @State private var weekly: WeeklyReport?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let metrics = metrics {
                        todayCard(metrics: metrics)
                    } else {
                        placeholderCard(title: "今日数据", text: "暂无记录，去对话页记一餐或一次运动吧")
                    }

                    if let weekly = weekly {
                        weeklyCard(weekly: weekly)
                    } else {
                        placeholderCard(title: "本周汇总", text: "周日自动生成周报")
                    }
                }
                .padding()
            }
            .navigationTitle("数据看板")
            .onAppear { loadData() }
        }
    }

    private func todayCard(metrics: DailyMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今日热量")
                .font(.headline)

            HStack {
                VStack(alignment: .leading) {
                    Text("\(metrics.totalIntakeKcal)")
                        .font(.title.bold())
                    Text("摄入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .leading) {
                    Text("\(metrics.totalExpenditureKcal)")
                        .font(.title.bold())
                    Text("消耗")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .leading) {
                    Text("\(metrics.deficitKcal)")
                        .font(.title.bold())
                        .foregroundStyle(metrics.deficitKcal > 0 ? .green : .red)
                    Text("缺口")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: Double(metrics.totalIntakeKcal), total: Double(metrics.totalExpenditureKcal))
                .tint(.blue)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func weeklyCard(weekly: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本周缺口")
                .font(.headline)

            HStack {
                VStack(alignment: .leading) {
                    Text("\(weekly.totalDeficitKcal)")
                        .font(.title.bold())
                    Text("总缺口 (kcal)")
                        .font(.caption)
                }
                Spacer()
                VStack(alignment: .leading) {
                    Text(String(format: "%.1f", weekly.projectedWeightLossKg))
                        .font(.title.bold())
                        .foregroundStyle(.green)
                    Text("预计减脂 (kg)")
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func placeholderCard(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func loadData() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let predicate = #Predicate<DailyMetrics> { $0.date == today }
        let descriptor = FetchDescriptor<DailyMetrics>(predicate: predicate)
        metrics = (try? modelContext.fetch(descriptor))?.first

        // TODO: 周报查询
    }
}

#Preview {
    DashboardScreen()
        .modelContainer(for: [DailyMetrics.self, WeeklyReport.self])
}
