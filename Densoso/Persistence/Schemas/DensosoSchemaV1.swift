import Foundation
import SwiftData

enum DensosoSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            UserProfile.self,
            MealRecord.self,
            DishEntry.self,
            WorkoutRecord.self,
            DailyMetrics.self,
            WeeklyReport.self,
            ScheduleEvent.self,
            HealthSyncOutboxEntry.self,
        ]
    }

    @Model
    final class UserProfile {
        var name: String
        var biologicalSex: String
        var dateOfBirth: Date
        var heightCm: Double
        var weightKg: Double
        var weightHistoryJSON: String
        var activityLevel: String
        var dailyDeficitTarget: Int
        var createdAt: Date
        var updatedAt: Date

        init(
            name: String = "",
            biologicalSex: String = "male",
            dateOfBirth: Date = Date(timeIntervalSince1970: 0),
            heightCm: Double = 170,
            weightKg: Double = 70,
            activityLevel: String = "sedentary",
            dailyDeficitTarget: Int = 500
        ) {
            self.name = name
            self.biologicalSex = biologicalSex
            self.dateOfBirth = dateOfBirth
            self.heightCm = heightCm
            self.weightKg = weightKg
            self.weightHistoryJSON = "[]"
            self.activityLevel = activityLevel
            self.dailyDeficitTarget = dailyDeficitTarget
            self.createdAt = Date()
            self.updatedAt = Date()
        }
    }

    @Model
    final class MealRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var date: Date
        var mealType: String
        var totalCaloriesKcal: Int
        var proteinG: Double
        var fatG: Double
        var carbsG: Double
        var notes: String?
        var confidence: String
        var algorithmVersion: String = "v1"
        var createdAt: Date

        @Relationship(deleteRule: .cascade, inverse: \DensosoSchemaV1.DishEntry.mealRecord)
        var dishes: [DensosoSchemaV1.DishEntry] = []

        init(
            date: Date = Date(),
            mealType: String = "lunch",
            totalCaloriesKcal: Int = 0,
            proteinG: Double = 0,
            fatG: Double = 0,
            carbsG: Double = 0,
            notes: String? = nil,
            confidence: String = "medium",
            algorithmVersion: String = "v2"
        ) {
            self.date = date
            self.mealType = mealType
            self.totalCaloriesKcal = totalCaloriesKcal
            self.proteinG = proteinG
            self.fatG = fatG
            self.carbsG = carbsG
            self.notes = notes
            self.confidence = confidence
            self.algorithmVersion = algorithmVersion
            self.createdAt = Date()
        }
    }

    @Model
    final class DishEntry {
        var dishName: String
        var cookingMethod: String?
        var ingredientJSON: String
        var estimatedCaloriesKcal: Int
        var estimatedProteinG: Double
        var estimatedFatG: Double
        var estimatedCarbsG: Double
        var confidenceScore: Double
        var userCorrectionFactor: Double?
        var createdAt: Date
        var mealRecord: DensosoSchemaV1.MealRecord?

        init(
            dishName: String,
            cookingMethod: String? = nil,
            ingredientJSON: String = "[]",
            estimatedCaloriesKcal: Int = 0,
            estimatedProteinG: Double = 0,
            estimatedFatG: Double = 0,
            estimatedCarbsG: Double = 0,
            confidenceScore: Double = 0.5,
            userCorrectionFactor: Double? = nil
        ) {
            self.dishName = dishName
            self.cookingMethod = cookingMethod
            self.ingredientJSON = ingredientJSON
            self.estimatedCaloriesKcal = estimatedCaloriesKcal
            self.estimatedProteinG = estimatedProteinG
            self.estimatedFatG = estimatedFatG
            self.estimatedCarbsG = estimatedCarbsG
            self.confidenceScore = confidenceScore
            self.userCorrectionFactor = userCorrectionFactor
            self.createdAt = Date()
        }
    }

    @Model
    final class WorkoutRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var date: Date
        var type: String
        var durationMinutes: Int
        var estimatedCaloriesBurned: Int
        var intensity: String
        var notes: String?
        var createdAt: Date

        init(
            date: Date = Date(),
            type: String = "other",
            durationMinutes: Int = 0,
            estimatedCaloriesBurned: Int = 0,
            intensity: String = "moderate",
            notes: String? = nil
        ) {
            self.date = date
            self.type = type
            self.durationMinutes = durationMinutes
            self.estimatedCaloriesBurned = estimatedCaloriesBurned
            self.intensity = intensity
            self.notes = notes
            self.createdAt = Date()
        }
    }

    @Model
    final class DailyMetrics {
        @Attribute(.unique) var date: Date
        var bmrKcal: Int
        var activeCaloriesKcal: Int
        var totalExpenditureKcal: Int
        var totalIntakeKcal: Int
        var deficitKcal: Int
        var proteinG: Double
        var fatG: Double
        var carbsG: Double
        var mealCount: Int
        var workoutCount: Int
        var computedAt: Date

        init(date: Date) {
            self.date = Calendar.current.startOfDay(for: date)
            self.bmrKcal = 0
            self.activeCaloriesKcal = 0
            self.totalExpenditureKcal = 0
            self.totalIntakeKcal = 0
            self.deficitKcal = 0
            self.proteinG = 0
            self.fatG = 0
            self.carbsG = 0
            self.mealCount = 0
            self.workoutCount = 0
            self.computedAt = Date()
        }
    }

    @Model
    final class WeeklyReport {
        @Attribute(.unique) var weekStartDate: Date
        var weekEndDate: Date
        var totalDeficitKcal: Int
        var avgDailyDeficitKcal: Double
        var projectedWeightLossKg: Double
        var avgProteinG: Double
        var avgFatG: Double
        var avgCarbsG: Double
        var bestDay: Date?
        var worstDay: Date?
        var mealsCount: Int
        var workoutsCount: Int
        var compliance: Double
        var generatedAt: Date

        init(weekStartDate: Date, weekEndDate: Date) {
            self.weekStartDate = weekStartDate
            self.weekEndDate = weekEndDate
            self.totalDeficitKcal = 0
            self.avgDailyDeficitKcal = 0
            self.projectedWeightLossKg = 0
            self.avgProteinG = 0
            self.avgFatG = 0
            self.avgCarbsG = 0
            self.bestDay = nil
            self.worstDay = nil
            self.mealsCount = 0
            self.workoutsCount = 0
            self.compliance = 0
            self.generatedAt = Date()
        }
    }

    @Model
    final class ScheduleEvent {
        var date: Date
        var title: String
        var notes: String?
        var startTime: Date
        var endTime: Date?
        var createdAt: Date

        init(
            date: Date = Date(),
            title: String = "",
            notes: String? = nil,
            startTime: Date = Date(),
            endTime: Date? = nil
        ) {
            self.date = date
            self.title = title
            self.notes = notes
            self.startTime = startTime
            self.endTime = endTime
            self.createdAt = Date()
        }
    }

    @Model
    final class HealthSyncOutboxEntry {
        @Attribute(.unique) var id: UUID
        var operation: String
        var recordID: UUID
        var createdAt: Date
        var state: String
        var lastError: String?

        init(operation: String, recordID: UUID, state: String = "pending") {
            self.id = UUID()
            self.operation = operation
            self.recordID = recordID
            self.createdAt = Date()
            self.state = state
        }
    }
}
