import Foundation
import SwiftData

@MainActor
@Observable
final class ExportService {
    var lastExportDate: Date?
    var isExporting = false
    var lastError: String?

    struct BackupPayload: Codable {
        let version: Int
        let exportedAt: Date
        let userProfile: UserProfileExport?
        let mealRecords: [MealRecordExport]
        let workoutRecords: [WorkoutRecordExport]
        let dailyMetrics: [DailyMetricsExport]

        struct UserProfileExport: Codable {
            let name: String; let biologicalSex: String; let dateOfBirth: Date
            let heightCm: Double; let weightKg: Double; let activityLevel: String
            let dailyDeficitTarget: Int
        }
        struct MealRecordExport: Codable {
            let date: Date; let mealType: String; let totalCaloriesKcal: Int
            let proteinG: Double; let fatG: Double; let carbsG: Double
            let dishes: [DishExport]
        }
        struct DishExport: Codable {
            let dishName: String; let cookingMethod: String?
            let estimatedCaloriesKcal: Int; let ingredientJSON: String
            let confidenceScore: Double
        }
        struct WorkoutRecordExport: Codable {
            let date: Date; let type: String; let durationMinutes: Int
            let estimatedCaloriesBurned: Int; let intensity: String
        }
        struct DailyMetricsExport: Codable {
            let date: Date; let deficitKcal: Int; let totalIntakeKcal: Int
            let totalExpenditureKcal: Int; let mealCount: Int; let workoutCount: Int
        }
    }

    func exportJSON(context: ModelContext) async throws -> URL {
        isExporting = true
        defer { isExporting = false }

        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
        let meals = try context.fetch(FetchDescriptor<MealRecord>())
        let workouts = try context.fetch(FetchDescriptor<WorkoutRecord>())
        let metrics = try context.fetch(FetchDescriptor<DailyMetrics>())

        let payload = BackupPayload(
            version: 1,
            exportedAt: Date(),
            userProfile: profiles.first.map { p in
                BackupPayload.UserProfileExport(
                    name: p.name, biologicalSex: p.biologicalSex,
                    dateOfBirth: p.dateOfBirth, heightCm: p.heightCm,
                    weightKg: p.weightKg, activityLevel: p.activityLevel,
                    dailyDeficitTarget: p.dailyDeficitTarget
                )
            },
            mealRecords: meals.map { meal in
                BackupPayload.MealRecordExport(
                    date: meal.date, mealType: meal.mealType,
                    totalCaloriesKcal: meal.totalCaloriesKcal,
                    proteinG: meal.proteinG, fatG: meal.fatG, carbsG: meal.carbsG,
                    dishes: meal.dishes.map { dish in
                        BackupPayload.DishExport(
                            dishName: dish.dishName,
                            cookingMethod: dish.cookingMethod,
                            estimatedCaloriesKcal: dish.estimatedCaloriesKcal,
                            ingredientJSON: dish.ingredientJSON,
                            confidenceScore: dish.confidenceScore
                        )
                    }
                )
            },
            workoutRecords: workouts.map { w in
                BackupPayload.WorkoutRecordExport(
                    date: w.date, type: w.type, durationMinutes: w.durationMinutes,
                    estimatedCaloriesBurned: w.estimatedCaloriesBurned, intensity: w.intensity
                )
            },
            dailyMetrics: metrics.map { m in
                BackupPayload.DailyMetricsExport(
                    date: m.date, deficitKcal: m.deficitKcal,
                    totalIntakeKcal: m.totalIntakeKcal,
                    totalExpenditureKcal: m.totalExpenditureKcal,
                    mealCount: m.mealCount, workoutCount: m.workoutCount
                )
            }
        )

        let jsonData = try JSONEncoder().encode(payload)
        let fileName = "densoso_backup_\(ISO8601DateFormatter().string(from: Date())).json"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try jsonData.write(to: tempURL)

        lastExportDate = Date()
        return tempURL
    }

    /// 恢复备份
    func restoreJSON(url: URL, context: ModelContext) async throws -> ImportSummary {
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(BackupPayload.self, from: data)

        // 清空现有数据（可选：先询问用户）
        try context.delete(model: UserProfile.self)
        try context.delete(model: MealRecord.self)
        try context.delete(model: WorkoutRecord.self)
        try context.delete(model: DailyMetrics.self)

        if let p = payload.userProfile {
            let profile = UserProfile(
                name: p.name, biologicalSex: p.biologicalSex, dateOfBirth: p.dateOfBirth,
                heightCm: p.heightCm, weightKg: p.weightKg, activityLevel: p.activityLevel,
                dailyDeficitTarget: p.dailyDeficitTarget
            )
            context.insert(profile)
        }

        for m in payload.mealRecords {
            let meal = MealRecord(
                date: m.date, mealType: m.mealType, totalCaloriesKcal: m.totalCaloriesKcal,
                proteinG: m.proteinG, fatG: m.fatG, carbsG: m.carbsG
            )
            meal.dishes = m.dishes.map { dish in
                let entry = DishEntry(
                    dishName: dish.dishName, cookingMethod: dish.cookingMethod,
                    estimatedCaloriesKcal: dish.estimatedCaloriesKcal,
                    confidenceScore: dish.confidenceScore
                )
                entry.ingredientJSON = dish.ingredientJSON
                return entry
            }
            context.insert(meal)
        }

        for w in payload.workoutRecords {
            context.insert(WorkoutRecord(
                date: w.date, type: w.type, durationMinutes: w.durationMinutes,
                estimatedCaloriesBurned: w.estimatedCaloriesBurned, intensity: w.intensity
            ))
        }

        for m in payload.dailyMetrics {
            context.insert(DailyMetrics(
                date: m.date, totalIntakeKcal: m.totalIntakeKcal,
                totalExpenditureKcal: m.totalExpenditureKcal, deficitKcal: m.deficitKcal,
                mealCount: m.mealCount, workoutCount: m.workoutCount
            ))
        }

        try context.save()

        return ImportSummary(
            meals: payload.mealRecords.count,
            workouts: payload.workoutRecords.count,
            dailyMetrics: payload.dailyMetrics.count
        )
    }

    struct ImportSummary {
        let meals: Int
        let workouts: Int
        let dailyMetrics: Int
    }
}
