import Combine
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
    private let pageReader = HistoryRecordPageReader()

    @State private var selectedKind: RecordKind = .meals
    @State private var dateScope: DateScope = .all
    @State private var selectedDate = Date()
    @State private var meals: [MealRecord] = []
    @State private var workouts: [WorkoutRecord] = []
    @State private var weights: [WeightRecord] = []
    @State private var mealCursor: HistoryRecordCursor?
    @State private var workoutCursor: HistoryRecordCursor?
    @State private var weightCursor: HistoryRecordCursor?
    @State private var mealsHaveMore = false
    @State private var workoutsHaveMore = false
    @State private var weightsHaveMore = false
    @State private var syncSummary = HistorySyncSummary(
        pendingCount: 0,
        failedCount: 0,
        latestSuccessfulImport: nil
    )
    @State private var hasNewerRecords = false
    @State private var loadError: String?

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
                    LabeledContent("待处理写入", value: "\(syncSummary.pendingCount)")
                    LabeledContent("需处理失败", value: "\(syncSummary.failedCount)")
                    LabeledContent("最近导入") {
                        if let lastSync = syncSummary.latestSuccessfulImport {
                            Text(lastSync, format: .dateTime.month().day().hour().minute())
                        } else {
                            Text("尚无成功导入")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if hasNewerRecords {
                    Section {
                        Button("记录已更新，刷新列表") { reloadSelectedRecords() }
                            .frame(maxWidth: .infinity)
                    }
                }

                if let loadError {
                    Section {
                        Label("记录加载失败：\(loadError)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
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
            .refreshable { reload() }
            .listStyle(.plain)
            .orbitScrollBackground()
            .navigationTitle("记录")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: reload)
            .onChange(of: selectedKind) { _, _ in reloadSelectedRecords() }
            .onChange(of: dateScope) { _, _ in reloadSelectedRecords() }
            .onChange(of: selectedDate) { _, _ in reloadSelectedRecords() }
            .onReceive(
                NotificationCenter.default.publisher(for: ModelContext.didSave)
                    .receive(on: DispatchQueue.main)
            ) { notification in
                handleModelContextSave(notification)
            }
        }
    }

    @ViewBuilder
    private var mealSection: some View {
        Section("餐食记录") {
            if meals.isEmpty {
                ContentUnavailableView(
                    "没有餐食记录",
                    systemImage: "fork.knife",
                    description: Text(dateScope == .day ? "所选日期没有已确认餐食。" : "已确认餐食会出现在这里。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(meals) { meal in
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
            if mealsHaveMore {
                Button("加载更早餐食") { loadOlderRecords() }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var workoutSection: some View {
        Section("运动记录") {
            if workouts.isEmpty {
                ContentUnavailableView(
                    "没有运动记录",
                    systemImage: "figure.run",
                    description: Text(dateScope == .day ? "所选日期没有已确认运动。" : "已确认或从 HealthKit 导入的运动会出现在这里。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(workouts) { workout in
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
            if workoutsHaveMore {
                Button("加载更早运动") { loadOlderRecords() }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var weightSection: some View {
        Section("体重记录") {
            if weights.isEmpty {
                ContentUnavailableView(
                    "没有手工体重记录",
                    systemImage: "scalemass",
                    description: Text(dateScope == .day ? "所选日期没有记录。" : "已确认的手工体重会出现在这里。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(weights) { weight in
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
            if weightsHaveMore {
                Button("加载更早体重") { loadOlderRecords() }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var selectedDateRange: HistoryRecordDateRange? {
        guard dateScope == .day else { return nil }
        let startDate = Calendar.current.startOfDay(for: selectedDate)
        let endDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate)
            ?? startDate.addingTimeInterval(86_400)
        return HistoryRecordDateRange(startDate: startDate, endDate: endDate)
    }

    private func reload() {
        reloadSelectedRecords()
        loadSyncSummary()
    }

    private func loadSyncSummary() {
        do {
            syncSummary = try pageReader.syncSummary(in: modelContext)
        } catch {
            loadError = "暂时无法更新 HealthKit 同步状态，请稍后重试。"
        }
    }

    private func reloadSelectedRecords() {
        hasNewerRecords = false
        meals = []
        workouts = []
        weights = []
        mealCursor = nil
        workoutCursor = nil
        weightCursor = nil
        mealsHaveMore = false
        workoutsHaveMore = false
        weightsHaveMore = false
        loadError = nil

        do {
            switch selectedKind {
            case .meals:
                let page = try pageReader.meals(in: modelContext, during: selectedDateRange)
                meals = page.records
                mealCursor = page.nextCursor
                mealsHaveMore = page.hasMore
            case .workouts:
                let page = try pageReader.workouts(in: modelContext, during: selectedDateRange)
                workouts = page.records
                workoutCursor = page.nextCursor
                workoutsHaveMore = page.hasMore
            case .weights:
                let page = try pageReader.weights(in: modelContext, during: selectedDateRange)
                weights = page.records
                weightCursor = page.nextCursor
                weightsHaveMore = page.hasMore
            }
        } catch {
            loadError = "暂时无法加载记录，请稍后重试。"
        }
    }

    private func handleModelContextSave(_ notification: Notification) {
        let identifierKeys: [ModelContext.NotificationKey] = [
            .insertedIdentifiers,
            .updatedIdentifiers,
            .deletedIdentifiers,
            .invalidatedAllIdentifiers,
        ]
        let potentiallyNewRecordKeys: [ModelContext.NotificationKey] = [
            .insertedIdentifiers,
            .updatedIdentifiers,
            .invalidatedAllIdentifiers,
        ]
        var changedEntityNames = Set<String>()
        for key in identifierKeys {
            guard let identifiers = notification.userInfo?[key] as? Set<PersistentIdentifier> else { continue }
            changedEntityNames.formUnion(identifiers.map(\.entityName))
        }
        var potentiallyNewEntityNames = Set<String>()
        for key in potentiallyNewRecordKeys {
            guard let identifiers = notification.userInfo?[key] as? Set<PersistentIdentifier> else { continue }
            potentiallyNewEntityNames.formUnion(identifiers.map(\.entityName))
        }

        let outboxEntity = Schema.entityName(for: HealthSyncOutboxEntry.self)
        let cursorEntity = Schema.entityName(for: HealthKitImportCursor.self)
        if changedEntityNames.contains(outboxEntity) || changedEntityNames.contains(cursorEntity) {
            loadSyncSummary()
        }

        let selectedEntity: String
        switch selectedKind {
        case .meals: selectedEntity = Schema.entityName(for: MealRecord.self)
        case .workouts: selectedEntity = Schema.entityName(for: WorkoutRecord.self)
        case .weights: selectedEntity = Schema.entityName(for: WeightRecord.self)
        }
        if changedEntityNames.contains(selectedEntity) {
            if shouldRefreshSelectedRecordsFromNewest {
                reloadSelectedRecords()
            } else if potentiallyNewEntityNames.contains(selectedEntity) {
                hasNewerRecords = true
            }
        }
    }

    private var shouldRefreshSelectedRecordsFromNewest: Bool {
        switch selectedKind {
        case .meals: !mealsHaveMore && meals.count <= HistoryRecordPageReader.pageSize
        case .workouts: !workoutsHaveMore && workouts.count <= HistoryRecordPageReader.pageSize
        case .weights: !weightsHaveMore && weights.count <= HistoryRecordPageReader.pageSize
        }
    }

    private func loadOlderRecords() {
        do {
            switch selectedKind {
            case .meals:
                guard let mealCursor else { return }
                let page = try pageReader.meals(in: modelContext, during: selectedDateRange, before: mealCursor)
                meals.append(contentsOf: page.records)
                self.mealCursor = page.nextCursor
                mealsHaveMore = page.hasMore
            case .workouts:
                guard let workoutCursor else { return }
                let page = try pageReader.workouts(in: modelContext, during: selectedDateRange, before: workoutCursor)
                workouts.append(contentsOf: page.records)
                self.workoutCursor = page.nextCursor
                workoutsHaveMore = page.hasMore
            case .weights:
                guard let weightCursor else { return }
                let page = try pageReader.weights(in: modelContext, during: selectedDateRange, before: weightCursor)
                weights.append(contentsOf: page.records)
                self.weightCursor = page.nextCursor
                weightsHaveMore = page.hasMore
            }
        } catch {
            loadError = "暂时无法加载更早记录，请稍后重试。"
        }
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
        let selected = offsets.compactMap { meals.indices.contains($0) ? meals[$0] : nil }
        for meal in selected {
            do {
                try HealthRepository(modelContext: modelContext).delete(meal)
                meals.removeAll { $0.id == meal.id }
            } catch {
                loadError = "暂时无法删除这条餐食记录，请稍后重试。"
            }
        }
        loadSyncSummary()
    }

    private func deleteWorkouts(offsets: IndexSet) {
        let selected = offsets.compactMap { workouts.indices.contains($0) ? workouts[$0] : nil }
        for workout in selected {
            do {
                try HealthRepository(modelContext: modelContext).delete(workout)
                workouts.removeAll { $0.id == workout.id }
            } catch {
                loadError = "暂时无法删除这条运动记录，请稍后重试。"
            }
        }
        loadSyncSummary()
    }

    private func deleteWeights(offsets: IndexSet) {
        let selected = offsets.compactMap { weights.indices.contains($0) ? weights[$0] : nil }
        for weight in selected {
            do {
                try HealthRepository(modelContext: modelContext).delete(weight)
                weights.removeAll { $0.id == weight.id }
            } catch {
                loadError = "暂时无法删除这条体重记录，请稍后重试。"
            }
        }
        loadSyncSummary()
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
