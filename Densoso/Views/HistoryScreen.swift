import SwiftData
import SwiftUI

struct HistoryScreen: View {
    private enum RecordKind: String, CaseIterable, Identifiable {
        case meals = "饮食"
        case workouts = "运动"
        case weights = "体重"

        var id: Self { self }
    }

    private enum DateScope: String, CaseIterable, Identifiable {
        case all = "全部"
        case day = "按日"

        var id: Self { self }
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MealRecord.date, order: .reverse) private var meals: [MealRecord]
    @Query(sort: \WorkoutRecord.date, order: .reverse) private var workouts: [WorkoutRecord]
    @Query(sort: \WeightRecord.measuredAt, order: .reverse) private var weights: [WeightRecord]
    @Query(sort: \HealthSyncOutboxEntry.createdAt, order: .reverse) private var healthOutbox: [HealthSyncOutboxEntry]
    @Query(sort: \HealthKitImportCursor.updatedAt, order: .reverse) private var healthCursors: [HealthKitImportCursor]

    @State private var selectedKind: RecordKind = .meals
    @State private var dateScope: DateScope = .all
    @State private var selectedDate = Date()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    OrbitScreenHeader(
                        eyebrow: "Records stay inspectable",
                        title: "按时间回看每一次确认。",
                        subtitle: "餐食、体重和 HealthKit 运动都保留来源与同步状态。"
                    )
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    Picker("记录类型", selection: $selectedKind) {
                        ForEach(RecordKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("日期范围", selection: $dateScope) {
                        ForEach(DateScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)

                    if dateScope == .day {
                        DatePicker("选择日期", selection: $selectedDate, displayedComponents: .date)
                    }
                }

                Section("HealthKit 同步") {
                    let pendingCount = healthOutbox.filter { ["pending", "sending", "retryable"].contains($0.state) }.count
                    let failedCount = healthOutbox.filter { $0.state == "terminal" }.count
                    let lastSync = healthCursors.compactMap(\.lastSuccessfulAt).max()
                    LabeledContent("待处理写入", value: "\(pendingCount)")
                    LabeledContent("需处理失败", value: "\(failedCount)")
                    LabeledContent("最近导入") {
                        if let lastSync {
                            Text(lastSync, format: .dateTime.month().day().hour().minute())
                        } else {
                            Text("尚无成功导入")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if selectedKind == .meals {
                    mealSection
                } else if selectedKind == .workouts {
                    workoutSection
                } else {
                    weightSection
                }
            }
            .listStyle(.plain)
            .orbitScrollBackground()
            .navigationTitle("记录")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var mealSection: some View {
        Section("餐食记录") {
            if filteredMeals.isEmpty {
                ContentUnavailableView(
                    "没有餐食记录",
                    systemImage: "fork.knife",
                    description: Text(dateScope == .day ? "所选日期没有已确认餐食。" : "已确认餐食会出现在这里。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredMeals) { meal in
                    HStack(spacing: 12) {
                        Image(systemName: "fork.knife.circle.fill")
                            .font(.title2)
                            .foregroundStyle(OrbitPalette.gold)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(mealTypeLabel(meal.mealType))
                                .font(.headline)
                            Text(meal.dishes.map(\.dishName).joined(separator: "、"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(meal.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()
                        Text("\(meal.totalCaloriesKcal) kcal")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 6)
                }
                .onDelete(perform: deleteMeals)
            }
        }
    }

    @ViewBuilder
    private var workoutSection: some View {
        Section("运动记录") {
            if filteredWorkouts.isEmpty {
                ContentUnavailableView(
                    "没有运动记录",
                    systemImage: "figure.run",
                    description: Text(dateScope == .day ? "所选日期没有已确认运动。" : "已确认或从 HealthKit 导入的运动会出现在这里。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredWorkouts) { workout in
                    HStack(spacing: 12) {
                        Image(systemName: "figure.run.circle.fill")
                            .font(.title2)
                            .foregroundStyle(OrbitPalette.blue)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(workout.type)
                                .font(.headline)
                            Text("\(workout.durationMinutes) 分钟 · \(workout.workoutOrigin)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(workout.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()
                        Text("\(workout.estimatedCaloriesBurned) kcal")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 6)
                }
                .onDelete(perform: deleteWorkouts)
            }
        }
    }

    @ViewBuilder
    private var weightSection: some View {
        Section("体重记录") {
            if filteredWeights.isEmpty {
                ContentUnavailableView(
                    "没有手工体重记录",
                    systemImage: "scalemass",
                    description: Text(dateScope == .day ? "所选日期没有记录。" : "已确认的手工体重会出现在这里。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredWeights) { weight in
                    HStack(spacing: 12) {
                        Image(systemName: "scalemass.fill")
                            .font(.title2)
                            .foregroundStyle(OrbitPalette.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(weight.measuredAt, format: .dateTime.month().day().hour().minute())
                                .font(.headline)
                            Text(weight.source == "healthKit" ? "Apple Health 导入" : "手工确认")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(weight.kilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 6)
                }
                .onDelete(perform: deleteWeights)
            }
        }
    }

    private var filteredMeals: [MealRecord] {
        guard dateScope == .day else { return meals }
        return meals.filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
    }

    private var filteredWorkouts: [WorkoutRecord] {
        guard dateScope == .day else { return workouts }
        return workouts.filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
    }

    private var filteredWeights: [WeightRecord] {
        guard dateScope == .day else { return weights }
        return weights.filter { Calendar.current.isDate($0.measuredAt, inSameDayAs: selectedDate) }
    }

    private func mealTypeLabel(_ type: String) -> String {
        switch type {
        case "breakfast": "早餐"
        case "lunch": "午餐"
        case "dinner": "晚餐"
        case "snack": "加餐"
        default: type
        }
    }

    private func deleteMeals(offsets: IndexSet) {
        let visibleMeals = filteredMeals
        for index in offsets {
            try? HealthRepository(modelContext: modelContext).delete(visibleMeals[index])
        }
    }

    private func deleteWorkouts(offsets: IndexSet) {
        let visibleWorkouts = filteredWorkouts
        for index in offsets {
            try? HealthRepository(modelContext: modelContext).delete(visibleWorkouts[index])
        }
    }

    private func deleteWeights(offsets: IndexSet) {
        let visibleWeights = filteredWeights
        for index in offsets {
            try? HealthRepository(modelContext: modelContext).delete(visibleWeights[index])
        }
    }
}

#Preview {
    HistoryScreen()
        .modelContainer(
            for: [
                MealRecord.self, DishEntry.self, WorkoutRecord.self, WeightRecord.self,
                HealthSyncOutboxEntry.self, HealthKitImportCursor.self,
            ],
            inMemory: true
        )
}
