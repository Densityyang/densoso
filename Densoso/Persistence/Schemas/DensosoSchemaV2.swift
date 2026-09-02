import Foundation
import SwiftData

enum DensosoSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [UserProfile.self, MealRecord.self, DishEntry.self, WorkoutRecord.self, DailyMetrics.self,
         WeeklyReport.self, ScheduleEvent.self, HealthSyncOutboxEntry.self, HealthKitImportCursor.self]
    }

    @Model final class UserProfile {
        var name: String; var biologicalSex: String; var dateOfBirth: Date
        var heightCm: Double; var weightKg: Double; var weightHistoryJSON: String
        var activityLevel: String; var dailyDeficitTarget: Int; var createdAt: Date; var updatedAt: Date
        init(name: String = "", biologicalSex: String = "male", dateOfBirth: Date = Date(timeIntervalSince1970: 0),
             heightCm: Double = 170, weightKg: Double = 70, activityLevel: String = "sedentary", dailyDeficitTarget: Int = 500) {
            self.name = name; self.biologicalSex = biologicalSex; self.dateOfBirth = dateOfBirth
            self.heightCm = heightCm; self.weightKg = weightKg; weightHistoryJSON = "[]"
            self.activityLevel = activityLevel; self.dailyDeficitTarget = dailyDeficitTarget
            createdAt = Date(); updatedAt = Date()
        }
    }

    @Model final class MealRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var date: Date; var mealType: String; var totalCaloriesKcal: Int
        var proteinG: Double; var fatG: Double; var carbsG: Double
        var notes: String?; var confidence: String; var algorithmVersion: String = "v1"; var createdAt: Date
        @Relationship(deleteRule: .cascade, inverse: \DensosoSchemaV2.DishEntry.mealRecord)
        var dishes: [DensosoSchemaV2.DishEntry] = []
        init(date: Date = Date(), mealType: String = "lunch", totalCaloriesKcal: Int = 0,
             proteinG: Double = 0, fatG: Double = 0, carbsG: Double = 0,
             notes: String? = nil, confidence: String = "medium", algorithmVersion: String = "v2") {
            self.date = date; self.mealType = mealType; self.totalCaloriesKcal = totalCaloriesKcal
            self.proteinG = proteinG; self.fatG = fatG; self.carbsG = carbsG
            self.notes = notes; self.confidence = confidence; self.algorithmVersion = algorithmVersion; createdAt = Date()
        }
    }

    @Model final class DishEntry {
        var dishName: String; var cookingMethod: String?; var ingredientJSON: String
        var estimatedCaloriesKcal: Int; var estimatedProteinG: Double; var estimatedFatG: Double; var estimatedCarbsG: Double
        var confidenceScore: Double; var userCorrectionFactor: Double?; var createdAt: Date
        var mealRecord: DensosoSchemaV2.MealRecord?
        init(dishName: String, cookingMethod: String? = nil, ingredientJSON: String = "[]",
             estimatedCaloriesKcal: Int = 0, estimatedProteinG: Double = 0, estimatedFatG: Double = 0,
             estimatedCarbsG: Double = 0, confidenceScore: Double = 0.5, userCorrectionFactor: Double? = nil) {
            self.dishName = dishName; self.cookingMethod = cookingMethod; self.ingredientJSON = ingredientJSON
            self.estimatedCaloriesKcal = estimatedCaloriesKcal; self.estimatedProteinG = estimatedProteinG
            self.estimatedFatG = estimatedFatG; self.estimatedCarbsG = estimatedCarbsG
            self.confidenceScore = confidenceScore; self.userCorrectionFactor = userCorrectionFactor; createdAt = Date()
        }
    }

    @Model final class WorkoutRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var date: Date; var type: String; var durationMinutes: Int; var estimatedCaloriesBurned: Int
        var intensity: String; var notes: String?; var createdAt: Date; var updatedAt: Date
        var healthKitUUID: UUID?; var logicalSessionID: UUID?; var workoutOrigin: String; var energySource: String?
        var sourceBundleIdentifier: String?; var sourceVersion: String?; var sourceRevision: String?
        var deviceName: String?; var deviceModel: String?; var dataQuality: String; var routeStatus: String; var routePointCount: Int?
        init(date: Date = Date(), type: String = "other", durationMinutes: Int = 0,
             estimatedCaloriesBurned: Int = 0, intensity: String = "moderate", notes: String? = nil,
             healthKitUUID: UUID? = nil, logicalSessionID: UUID? = nil, workoutOrigin: String = "userEntered",
             energySource: String? = "userEntered", sourceBundleIdentifier: String? = nil, sourceVersion: String? = nil,
             sourceRevision: String? = nil, deviceName: String? = nil, deviceModel: String? = nil,
             dataQuality: String = "complete", routeStatus: String = "unavailable", routePointCount: Int? = nil) {
            self.date = date; self.type = type; self.durationMinutes = durationMinutes
            self.estimatedCaloriesBurned = estimatedCaloriesBurned; self.intensity = intensity; self.notes = notes
            createdAt = Date(); updatedAt = Date(); self.healthKitUUID = healthKitUUID; self.logicalSessionID = logicalSessionID
            self.workoutOrigin = workoutOrigin; self.energySource = energySource; self.sourceBundleIdentifier = sourceBundleIdentifier
            self.sourceVersion = sourceVersion; self.sourceRevision = sourceRevision; self.deviceName = deviceName
            self.deviceModel = deviceModel; self.dataQuality = dataQuality; self.routeStatus = routeStatus
            self.routePointCount = routePointCount
        }
    }

    @Model final class DailyMetrics {
        @Attribute(.unique) var date: Date
        var bmrKcal: Int; var activeCaloriesKcal: Int; var totalExpenditureKcal: Int; var totalIntakeKcal: Int; var deficitKcal: Int
        var proteinG: Double; var fatG: Double; var carbsG: Double; var mealCount: Int; var workoutCount: Int; var computedAt: Date
        init(date: Date, bmrKcal: Int = 0, activeCaloriesKcal: Int = 0, totalExpenditureKcal: Int = 0,
             totalIntakeKcal: Int = 0, deficitKcal: Int = 0, proteinG: Double = 0, fatG: Double = 0,
             carbsG: Double = 0, mealCount: Int = 0, workoutCount: Int = 0) {
            self.date = Calendar.current.startOfDay(for: date); self.bmrKcal = bmrKcal
            self.activeCaloriesKcal = activeCaloriesKcal; self.totalExpenditureKcal = totalExpenditureKcal
            self.totalIntakeKcal = totalIntakeKcal; self.deficitKcal = deficitKcal; self.proteinG = proteinG
            self.fatG = fatG; self.carbsG = carbsG; self.mealCount = mealCount; self.workoutCount = workoutCount; computedAt = Date()
        }
    }

    @Model final class WeeklyReport {
        @Attribute(.unique) var weekStartDate: Date
        var weekEndDate: Date; var totalDeficitKcal: Int; var avgDailyDeficitKcal: Double; var projectedWeightLossKg: Double
        var avgProteinG: Double; var avgFatG: Double; var avgCarbsG: Double; var bestDay: Date?; var worstDay: Date?
        var mealsCount: Int; var workoutsCount: Int; var compliance: Double; var generatedAt: Date
        init(weekStartDate: Date, weekEndDate: Date) {
            self.weekStartDate = weekStartDate; self.weekEndDate = weekEndDate; totalDeficitKcal = 0
            avgDailyDeficitKcal = 0; projectedWeightLossKg = 0; avgProteinG = 0; avgFatG = 0; avgCarbsG = 0
            mealsCount = 0; workoutsCount = 0; compliance = 0; generatedAt = Date()
        }
    }

    @Model final class ScheduleEvent {
        var date: Date; var title: String; var notes: String?; var startTime: Date; var endTime: Date?; var createdAt: Date
        init(date: Date = Date(), title: String = "", notes: String? = nil,
             startTime: Date = Date(), endTime: Date? = nil) {
            self.date = date; self.title = title; self.notes = notes; self.startTime = startTime
            self.endTime = endTime; createdAt = Date()
        }
    }

    @Model final class HealthSyncOutboxEntry {
        @Attribute(.unique) var id: UUID
        var operation: String; var recordID: UUID; var createdAt: Date; var state: String; var lastError: String?
        init(operation: String, recordID: UUID, state: String = "pending") {
            id = UUID(); self.operation = operation; self.recordID = recordID; createdAt = Date(); self.state = state
        }
    }

    @Model final class HealthKitImportCursor {
        @Attribute(.unique) var stream: String
        var anchorData: Data?; var updatedAt: Date
        init(stream: String, anchorData: Data? = nil) {
            self.stream = stream; self.anchorData = anchorData; updatedAt = Date()
        }
    }
}
