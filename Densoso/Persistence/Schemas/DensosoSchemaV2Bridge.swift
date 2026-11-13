import Foundation
import SwiftData

enum DensosoSchemaV2Bridge: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 1, 0) }
    static var models: [any PersistentModel.Type] {
        [UserProfile.self, MealRecord.self, DishEntry.self, WorkoutRecord.self, DailyMetrics.self,
         WeeklyReport.self, ScheduleEvent.self, HealthSyncOutboxEntry.self, HealthKitImportCursor.self]
    }

    @Model final class UserProfile {
        var name: String; var biologicalSex: String; var dateOfBirth: Date
        var heightCm: Double; var weightKg: Double; var weightHistoryJSON: String
        var activityLevel: String; var dailyDeficitTarget: Int; var createdAt: Date; var updatedAt: Date
        init(name: String = "") {
            self.name = name; biologicalSex = "male"; dateOfBirth = Date(timeIntervalSince1970: 0)
            heightCm = 170; weightKg = 70; weightHistoryJSON = "[]"; activityLevel = "sedentary"
            dailyDeficitTarget = 500; createdAt = Date(); updatedAt = Date()
        }
    }

    @Model final class MealRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var date: Date; var mealType: String; var totalCaloriesKcal: Int
        var proteinG: Double; var fatG: Double; var carbsG: Double
        var notes: String?; var confidence: String; var algorithmVersion: String = "v1"; var createdAt: Date
        var energyLowKcal: Double?; var energyLikelyKcal: Double?; var energyHighKcal: Double?
        var proteinLowG: Double?; var proteinLikelyG: Double?; var proteinHighG: Double?
        var fatLowG: Double?; var fatLikelyG: Double?; var fatHighG: Double?
        var carbsLowG: Double?; var carbsLikelyG: Double?; var carbsHighG: Double?
        var evidenceData: Data?; var sourceActionKey: String?
        @Relationship(deleteRule: .cascade, inverse: \DensosoSchemaV2Bridge.DishEntry.mealRecord)
        var dishes: [DensosoSchemaV2Bridge.DishEntry] = []
        init(date: Date = Date()) {
            self.date = date; mealType = "lunch"; totalCaloriesKcal = 0; proteinG = 0; fatG = 0; carbsG = 0
            confidence = "medium"; createdAt = Date()
        }
    }

    @Model final class DishEntry {
        var dishName: String; var cookingMethod: String?; var ingredientJSON: String
        var estimatedCaloriesKcal: Int; var estimatedProteinG: Double; var estimatedFatG: Double; var estimatedCarbsG: Double
        var confidenceScore: Double; var userCorrectionFactor: Double?; var createdAt: Date
        var id: UUID?
        var energyLowKcal: Double?; var energyLikelyKcal: Double?; var energyHighKcal: Double?
        var proteinLowG: Double?; var proteinLikelyG: Double?; var proteinHighG: Double?
        var fatLowG: Double?; var fatLikelyG: Double?; var fatHighG: Double?
        var carbsLowG: Double?; var carbsLikelyG: Double?; var carbsHighG: Double?
        var portionLowG: Double?; var portionLikelyG: Double?; var portionHighG: Double?
        var evidenceData: Data?; var algorithmVersion: String?
        var mealRecord: DensosoSchemaV2Bridge.MealRecord?
        init(dishName: String) {
            self.dishName = dishName; ingredientJSON = "[]"; estimatedCaloriesKcal = 0
            estimatedProteinG = 0; estimatedFatG = 0; estimatedCarbsG = 0
            confidenceScore = 0.5; createdAt = Date()
        }
    }

    @Model final class WorkoutRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var date: Date; var type: String; var durationMinutes: Int; var estimatedCaloriesBurned: Int
        var intensity: String; var notes: String?; var createdAt: Date; var updatedAt: Date
        var healthKitUUID: UUID?; var logicalSessionID: UUID?; var workoutOrigin: String; var energySource: String?
        var sourceBundleIdentifier: String?; var sourceVersion: String?; var sourceRevision: String?
        var deviceName: String?; var deviceModel: String?; var dataQuality: String; var routeStatus: String; var routePointCount: Int?
        init(date: Date = Date()) {
            self.date = date; type = "other"; durationMinutes = 0; estimatedCaloriesBurned = 0
            intensity = "moderate"; createdAt = Date(); updatedAt = Date(); workoutOrigin = "userEntered"
            dataQuality = "complete"; routeStatus = "unavailable"
        }
    }

    @Model final class DailyMetrics {
        @Attribute(.unique) var date: Date
        var bmrKcal: Int; var activeCaloriesKcal: Int; var totalExpenditureKcal: Int; var totalIntakeKcal: Int; var deficitKcal: Int
        var proteinG: Double; var fatG: Double; var carbsG: Double; var mealCount: Int; var workoutCount: Int; var computedAt: Date
        init(date: Date) {
            self.date = date; bmrKcal = 0; activeCaloriesKcal = 0; totalExpenditureKcal = 0
            totalIntakeKcal = 0; deficitKcal = 0; proteinG = 0; fatG = 0; carbsG = 0
            mealCount = 0; workoutCount = 0; computedAt = Date()
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
        init(date: Date = Date(), title: String = "") { self.date = date; self.title = title; startTime = date; createdAt = Date() }
    }

    @Model final class HealthSyncOutboxEntry {
        @Attribute(.unique) var id: UUID
        var operation: String; var recordID: UUID; var createdAt: Date; var state: String; var lastError: String?
        var idempotencyKey: String?; var payloadData: Data?; var receiptID: UUID?
        var attemptCount: Int?; var nextAttemptAt: Date?; var syncIdentifier: String?; var syncVersion: Int?
        init(operation: String, recordID: UUID) {
            id = UUID(); self.operation = operation; self.recordID = recordID; createdAt = Date(); state = "pending"
        }
    }

    @Model final class HealthKitImportCursor {
        @Attribute(.unique) var stream: String
        var anchorData: Data?; var updatedAt: Date; var lastSuccessfulAt: Date?; var lookbackStart: Date?
        init(stream: String) { self.stream = stream; updatedAt = Date() }
    }
}
