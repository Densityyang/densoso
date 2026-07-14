import SwiftUI
import SwiftData

struct HistoryScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MealRecord.date, order: .reverse) private var meals: [MealRecord]
    @Query(sort: \WorkoutRecord.date, order: .reverse) private var workouts: [WorkoutRecord]

    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            VStack {
                Picker("类型", selection: $selectedTab) {
                    Text("饮食").tag(0)
                    Text("运动").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == 0 {
                    mealList
                } else {
                    workoutList
                }
            }
            .navigationTitle("历史")
        }
    }

    private var mealList: some View {
        List {
            ForEach(meals) { meal in
                VStack(alignment: .leading) {
                    HStack {
                        Text(mealTypeLabel(meal.mealType))
                            .font(.headline)
                        Spacer()
                        Text("\(meal.totalCaloriesKcal) kcal")
                            .font(.subheadline.bold())
                    }
                    Text(meal.dishes.map(\.dishName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete(perform: deleteMeals)
        }
    }

    private var workoutList: some View {
        List {
            ForEach(workouts) { workout in
                HStack {
                    VStack(alignment: .leading) {
                        Text(workout.type)
                            .font(.headline)
                        Text("\(workout.durationMinutes) 分钟")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(workout.estimatedCaloriesBurned) kcal")
                        .font(.subheadline.bold())
                }
            }
            .onDelete(perform: deleteWorkouts)
        }
    }

    private func mealTypeLabel(_ type: String) -> String {
        switch type {
        case "breakfast": return "早餐"
        case "lunch": return "午餐"
        case "dinner": return "晚餐"
        case "snack": return "加餐"
        default: return type
        }
    }

    private func deleteMeals(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(meals[index])
        }
        try? modelContext.save()
    }

    private func deleteWorkouts(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(workouts[index])
        }
        try? modelContext.save()
    }
}

#Preview {
    HistoryScreen()
        .modelContainer(for: [MealRecord.self, WorkoutRecord.self])
}
