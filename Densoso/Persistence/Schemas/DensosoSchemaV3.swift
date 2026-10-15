import Foundation
import SwiftData

enum DensosoSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            UserProfile.self, MealRecord.self, DishEntry.self, WorkoutRecord.self,
            DailyMetrics.self, WeeklyReport.self, ScheduleEvent.self,
            HealthSyncOutboxEntry.self, HealthKitImportCursor.self,
            ConversationRecord.self, MessageRecord.self, PendingActionRecord.self,
            CommittedActionReceiptRecord.self, WeightRecord.self, GoalProfileRecord.self,
            DailyHealthSnapshotRecord.self, ProviderUsageRecord.self,
            DailyBriefRecord.self, WeeklyBriefRecord.self,
            WatchMessageReceiptRecord.self, ConsentRecord.self,
        ]
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
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var sourceActionKey: String
        var date: Date; var mealType: String; var totalCaloriesKcal: Int
        var proteinG: Double; var fatG: Double; var carbsG: Double
        var notes: String?; var confidence: String; var algorithmVersion: String; var createdAt: Date
        var energyLowKcal: Double; var energyLikelyKcal: Double; var energyHighKcal: Double
        var proteinLowG: Double?; var proteinLikelyG: Double?; var proteinHighG: Double?
        var fatLowG: Double?; var fatLikelyG: Double?; var fatHighG: Double?
        var carbsLowG: Double?; var carbsLikelyG: Double?; var carbsHighG: Double?
        var evidenceData: Data?
        @Relationship(deleteRule: .cascade, inverse: \DensosoSchemaV3.DishEntry.mealRecord)
        var dishes: [DensosoSchemaV3.DishEntry] = []

        init(
            id: UUID = UUID(), date: Date = Date(), mealType: String = "lunch",
            totalCaloriesKcal: Int = 0, proteinG: Double = 0, fatG: Double = 0, carbsG: Double = 0,
            notes: String? = nil, confidence: String = "medium", algorithmVersion: String = "v3",
            sourceActionKey: String? = nil,
            energyLowKcal: Double? = nil, energyLikelyKcal: Double? = nil, energyHighKcal: Double? = nil,
            proteinLowG: Double? = nil, proteinLikelyG: Double? = nil, proteinHighG: Double? = nil,
            fatLowG: Double? = nil, fatLikelyG: Double? = nil, fatHighG: Double? = nil,
            carbsLowG: Double? = nil, carbsLikelyG: Double? = nil, carbsHighG: Double? = nil,
            evidenceData: Data? = nil
        ) {
            self.id = id; self.sourceActionKey = sourceActionKey ?? "manual-meal-\(id.uuidString.lowercased())"
            self.date = date; self.mealType = mealType; self.totalCaloriesKcal = totalCaloriesKcal
            self.proteinG = proteinG; self.fatG = fatG; self.carbsG = carbsG; self.notes = notes
            self.confidence = confidence; self.algorithmVersion = algorithmVersion; createdAt = Date()
            let point = Double(totalCaloriesKcal)
            self.energyLowKcal = energyLowKcal ?? point
            self.energyLikelyKcal = energyLikelyKcal ?? point
            self.energyHighKcal = energyHighKcal ?? point
            self.proteinLowG = proteinLowG; self.proteinLikelyG = proteinLikelyG; self.proteinHighG = proteinHighG
            self.fatLowG = fatLowG; self.fatLikelyG = fatLikelyG; self.fatHighG = fatHighG
            self.carbsLowG = carbsLowG; self.carbsLikelyG = carbsLikelyG; self.carbsHighG = carbsHighG
            self.evidenceData = evidenceData
        }
    }

    @Model final class DishEntry {
        @Attribute(.unique) var id: UUID
        var dishName: String; var cookingMethod: String?; var ingredientJSON: String
        var estimatedCaloriesKcal: Int; var estimatedProteinG: Double; var estimatedFatG: Double; var estimatedCarbsG: Double
        var confidenceScore: Double; var userCorrectionFactor: Double?; var createdAt: Date
        var energyLowKcal: Double; var energyLikelyKcal: Double; var energyHighKcal: Double
        var proteinLowG: Double?; var proteinLikelyG: Double?; var proteinHighG: Double?
        var fatLowG: Double?; var fatLikelyG: Double?; var fatHighG: Double?
        var carbsLowG: Double?; var carbsLikelyG: Double?; var carbsHighG: Double?
        var portionLowG: Double?; var portionLikelyG: Double?; var portionHighG: Double?
        var evidenceData: Data?; var algorithmVersion: String
        var mealRecord: DensosoSchemaV3.MealRecord?

        init(
            id: UUID = UUID(), dishName: String, cookingMethod: String? = nil, ingredientJSON: String = "[]",
            estimatedCaloriesKcal: Int = 0, estimatedProteinG: Double = 0, estimatedFatG: Double = 0,
            estimatedCarbsG: Double = 0, confidenceScore: Double = 0.5, userCorrectionFactor: Double? = nil,
            energyLowKcal: Double? = nil, energyLikelyKcal: Double? = nil, energyHighKcal: Double? = nil,
            proteinLowG: Double? = nil, proteinLikelyG: Double? = nil, proteinHighG: Double? = nil,
            fatLowG: Double? = nil, fatLikelyG: Double? = nil, fatHighG: Double? = nil,
            carbsLowG: Double? = nil, carbsLikelyG: Double? = nil, carbsHighG: Double? = nil,
            portionLowG: Double? = nil, portionLikelyG: Double? = nil, portionHighG: Double? = nil,
            evidenceData: Data? = nil, algorithmVersion: String = "v3"
        ) {
            self.id = id; self.dishName = dishName; self.cookingMethod = cookingMethod; self.ingredientJSON = ingredientJSON
            self.estimatedCaloriesKcal = estimatedCaloriesKcal; self.estimatedProteinG = estimatedProteinG
            self.estimatedFatG = estimatedFatG; self.estimatedCarbsG = estimatedCarbsG
            self.confidenceScore = confidenceScore; self.userCorrectionFactor = userCorrectionFactor; createdAt = Date()
            let point = Double(estimatedCaloriesKcal)
            self.energyLowKcal = energyLowKcal ?? point; self.energyLikelyKcal = energyLikelyKcal ?? point
            self.energyHighKcal = energyHighKcal ?? point
            self.proteinLowG = proteinLowG; self.proteinLikelyG = proteinLikelyG; self.proteinHighG = proteinHighG
            self.fatLowG = fatLowG; self.fatLikelyG = fatLikelyG; self.fatHighG = fatHighG
            self.carbsLowG = carbsLowG; self.carbsLikelyG = carbsLikelyG; self.carbsHighG = carbsHighG
            self.portionLowG = portionLowG; self.portionLikelyG = portionLikelyG; self.portionHighG = portionHighG
            self.evidenceData = evidenceData; self.algorithmVersion = algorithmVersion
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
            self.date = date; self.type = type; self.durationMinutes = durationMinutes; self.estimatedCaloriesBurned = estimatedCaloriesBurned
            self.intensity = intensity; self.notes = notes; createdAt = Date(); updatedAt = Date()
            self.healthKitUUID = healthKitUUID; self.logicalSessionID = logicalSessionID; self.workoutOrigin = workoutOrigin
            self.energySource = energySource; self.sourceBundleIdentifier = sourceBundleIdentifier; self.sourceVersion = sourceVersion
            self.sourceRevision = sourceRevision; self.deviceName = deviceName; self.deviceModel = deviceModel
            self.dataQuality = dataQuality; self.routeStatus = routeStatus; self.routePointCount = routePointCount
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
            self.totalIntakeKcal = totalIntakeKcal; self.deficitKcal = deficitKcal
            self.proteinG = proteinG; self.fatG = fatG; self.carbsG = carbsG
            self.mealCount = mealCount; self.workoutCount = workoutCount; computedAt = Date()
        }
    }

    @Model final class WeeklyReport {
        @Attribute(.unique) var weekStartDate: Date
        var weekEndDate: Date; var totalDeficitKcal: Int; var avgDailyDeficitKcal: Double; var projectedWeightLossKg: Double
        var avgProteinG: Double; var avgFatG: Double; var avgCarbsG: Double; var bestDay: Date?; var worstDay: Date?
        var mealsCount: Int; var workoutsCount: Int; var compliance: Double; var generatedAt: Date
        init(weekStartDate: Date, weekEndDate: Date, totalDeficitKcal: Int = 0,
             avgDailyDeficitKcal: Double = 0, projectedWeightLossKg: Double = 0,
             avgProteinG: Double = 0, avgFatG: Double = 0, avgCarbsG: Double = 0,
             bestDay: Date? = nil, worstDay: Date? = nil, mealsCount: Int = 0,
             workoutsCount: Int = 0, compliance: Double = 0) {
            self.weekStartDate = weekStartDate; self.weekEndDate = weekEndDate; self.totalDeficitKcal = totalDeficitKcal
            self.avgDailyDeficitKcal = avgDailyDeficitKcal; self.projectedWeightLossKg = projectedWeightLossKg
            self.avgProteinG = avgProteinG; self.avgFatG = avgFatG; self.avgCarbsG = avgCarbsG
            self.bestDay = bestDay; self.worstDay = worstDay; self.mealsCount = mealsCount
            self.workoutsCount = workoutsCount; self.compliance = compliance; generatedAt = Date()
        }
    }

    @Model final class ScheduleEvent {
        var date: Date; var title: String; var notes: String?; var startTime: Date; var endTime: Date?; var createdAt: Date
        init(date: Date = Date(), title: String = "", notes: String? = nil,
             startTime: Date = Date(), endTime: Date? = nil) {
            self.date = date; self.title = title; self.notes = notes; self.startTime = startTime; self.endTime = endTime; createdAt = Date()
        }
    }

    @Model final class HealthSyncOutboxEntry {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var idempotencyKey: String
        var operation: String; var recordID: UUID; var payloadData: Data; var receiptID: UUID?
        var createdAt: Date; var attemptCount: Int; var nextAttemptAt: Date?; var state: String; var lastError: String?
        var syncIdentifier: String; var syncVersion: Int
        init(id: UUID = UUID(), operation: String, recordID: UUID, payloadData: Data = Data(),
             receiptID: UUID? = nil, idempotencyKey: String? = nil, state: String = "pending",
             attemptCount: Int = 0, nextAttemptAt: Date? = nil, syncIdentifier: String? = nil, syncVersion: Int = 1) {
            self.id = id; self.operation = operation; self.recordID = recordID; self.payloadData = payloadData
            self.receiptID = receiptID; self.idempotencyKey = idempotencyKey ?? "outbox-\(id.uuidString.lowercased())"
            createdAt = Date(); self.attemptCount = attemptCount; self.nextAttemptAt = nextAttemptAt; self.state = state
            self.syncIdentifier = syncIdentifier ?? "densoso.\(operation).\(recordID.uuidString.lowercased())"
            self.syncVersion = syncVersion
        }
    }

    @Model final class HealthKitImportCursor {
        @Attribute(.unique) var stream: String
        var anchorData: Data?; var updatedAt: Date; var lastSuccessfulAt: Date?; var lookbackStart: Date?
        init(stream: String, anchorData: Data? = nil, lastSuccessfulAt: Date? = nil, lookbackStart: Date? = nil) {
            self.stream = stream; self.anchorData = anchorData; updatedAt = Date()
            self.lastSuccessfulAt = lastSuccessfulAt; self.lookbackStart = lookbackStart
        }
    }

    @Model final class ConversationRecord {
        @Attribute(.unique) var id: UUID
        var state: String; var title: String?; var createdAt: Date; var updatedAt: Date
        init(id: UUID = UUID(), state: String = "active", title: String? = nil) {
            self.id = id; self.state = state; self.title = title; createdAt = Date(); updatedAt = Date()
        }
    }

    @Model final class MessageRecord {
        @Attribute(.unique) var id: UUID
        var conversationID: UUID; var roleRaw: String; var contentData: Data
        var toolSummaryData: Data?; var ordinal: Int; var requestID: UUID?; var createdAt: Date
        init(id: UUID = UUID(), conversationID: UUID, roleRaw: String, contentData: Data,
             toolSummaryData: Data? = nil, ordinal: Int, requestID: UUID? = nil) {
            self.id = id; self.conversationID = conversationID; self.roleRaw = roleRaw; self.contentData = contentData
            self.toolSummaryData = toolSummaryData; self.ordinal = ordinal; self.requestID = requestID; createdAt = Date()
        }
    }

    @Model final class PendingActionRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var idempotencyKey: String
        var actionTypeRaw: String; var canonicalPayloadData: Data; var payloadData: Data
        var schemaVersion: Int; var clientRequestID: UUID
        var stateRaw: String; var createdAt: Date; var updatedAt: Date; var expiresAt: Date
        var failureCode: String?; var failureDetail: String?
        init(id: UUID = UUID(), idempotencyKey: String, actionTypeRaw: String,
             canonicalPayloadData: Data, payloadData: Data, schemaVersion: Int = 1, clientRequestID: UUID,
             stateRaw: String = "pending", createdAt: Date = Date(), expiresAt: Date) {
            self.id = id; self.idempotencyKey = idempotencyKey; self.actionTypeRaw = actionTypeRaw
            self.canonicalPayloadData = canonicalPayloadData; self.payloadData = payloadData; self.schemaVersion = schemaVersion
            self.clientRequestID = clientRequestID; self.stateRaw = stateRaw
            self.createdAt = createdAt; updatedAt = createdAt; self.expiresAt = expiresAt
        }
    }

    @Model final class CommittedActionReceiptRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var actionID: UUID
        @Attribute(.unique) var idempotencyKey: String
        var actionTypeRaw: String; var localRecordID: UUID; var outboxIDsData: Data
        var committedAt: Date; var healthSyncStateRaw: String
        init(id: UUID = UUID(), actionID: UUID, idempotencyKey: String, actionTypeRaw: String,
             localRecordID: UUID, outboxIDsData: Data, committedAt: Date = Date(), healthSyncStateRaw: String = "pending") {
            self.id = id; self.actionID = actionID; self.idempotencyKey = idempotencyKey
            self.actionTypeRaw = actionTypeRaw; self.localRecordID = localRecordID
            self.outboxIDsData = outboxIDsData; self.committedAt = committedAt; self.healthSyncStateRaw = healthSyncStateRaw
        }
    }

    @Model final class WeightRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var sourceActionKey: String
        var measuredAt: Date; var kilograms: Double; var source: String; var algorithmVersion: String; var createdAt: Date
        init(id: UUID = UUID(), sourceActionKey: String, measuredAt: Date, kilograms: Double,
             source: String = "manual", algorithmVersion: String = "v3") {
            self.id = id; self.sourceActionKey = sourceActionKey; self.measuredAt = measuredAt
            self.kilograms = kilograms; self.source = source; self.algorithmVersion = algorithmVersion; createdAt = Date()
        }
    }

    @Model final class GoalProfileRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var profileKey: String
        var targetWeightKilograms: Double?; var dailyDeficitKcal: Int?; var dailyProteinGrams: Double?
        var effectiveFrom: Date; var updatedAt: Date
        init(id: UUID = UUID(), profileKey: String = "primary", targetWeightKilograms: Double? = nil,
             dailyDeficitKcal: Int? = nil, dailyProteinGrams: Double? = nil, effectiveFrom: Date = Date()) {
            self.id = id; self.profileKey = profileKey; self.targetWeightKilograms = targetWeightKilograms
            self.dailyDeficitKcal = dailyDeficitKcal; self.dailyProteinGrams = dailyProteinGrams
            self.effectiveFrom = effectiveFrom; updatedAt = Date()
        }
    }

    @Model final class DailyHealthSnapshotRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var dayKey: String
        var timezoneID: String; var payloadData: Data; var snapshotHash: String; var algorithmVersion: String; var createdAt: Date
        init(id: UUID = UUID(), dayKey: String, timezoneID: String, payloadData: Data,
             snapshotHash: String, algorithmVersion: String) {
            self.id = id; self.dayKey = dayKey; self.timezoneID = timezoneID; self.payloadData = payloadData
            self.snapshotHash = snapshotHash; self.algorithmVersion = algorithmVersion; createdAt = Date()
        }
    }

    @Model final class ProviderUsageRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var usageKey: String
        var provider: String; var model: String; var capability: String
        var inputTokens: Int; var outputTokens: Int; var audioSeconds: Double
        var estimatedCostMicros: Int64; var currency: String; var rateVersion: String; var createdAt: Date
        init(id: UUID = UUID(), usageKey: String, provider: String, model: String, capability: String) {
            self.id = id; self.usageKey = usageKey; self.provider = provider; self.model = model
            self.capability = capability; inputTokens = 0; outputTokens = 0; audioSeconds = 0
            estimatedCostMicros = 0; currency = "USD"; rateVersion = "unknown"; createdAt = Date()
        }
    }

    @Model final class DailyBriefRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var cacheKey: String
        var dayKey: String; var snapshotHash: String; var algorithmVersion: String; var payloadData: Data; var generatedAt: Date
        init(id: UUID = UUID(), cacheKey: String, dayKey: String, snapshotHash: String,
             algorithmVersion: String, payloadData: Data) {
            self.id = id; self.cacheKey = cacheKey; self.dayKey = dayKey; self.snapshotHash = snapshotHash
            self.algorithmVersion = algorithmVersion; self.payloadData = payloadData; generatedAt = Date()
        }
    }

    @Model final class WeeklyBriefRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var cacheKey: String
        var weekKey: String; var snapshotHash: String; var algorithmVersion: String; var payloadData: Data; var generatedAt: Date
        init(id: UUID = UUID(), cacheKey: String, weekKey: String, snapshotHash: String,
             algorithmVersion: String, payloadData: Data) {
            self.id = id; self.cacheKey = cacheKey; self.weekKey = weekKey; self.snapshotHash = snapshotHash
            self.algorithmVersion = algorithmVersion; self.payloadData = payloadData; generatedAt = Date()
        }
    }

    @Model final class WatchMessageReceiptRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var messageID: String
        var schemaVersion: Int; var payloadHash: String; var state: String; var processedAt: Date?
        init(id: UUID = UUID(), messageID: String, schemaVersion: Int, payloadHash: String, state: String = "pending") {
            self.id = id; self.messageID = messageID; self.schemaVersion = schemaVersion
            self.payloadHash = payloadHash; self.state = state
        }
    }

    @Model final class ConsentRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var consentKey: String
        var kind: String; var policyVersion: String; var granted: Bool; var decidedAt: Date; var revokedAt: Date?
        init(id: UUID = UUID(), consentKey: String, kind: String, policyVersion: String,
             granted: Bool, decidedAt: Date = Date(), revokedAt: Date? = nil) {
            self.id = id; self.consentKey = consentKey; self.kind = kind; self.policyVersion = policyVersion
            self.granted = granted; self.decidedAt = decidedAt; self.revokedAt = revokedAt
        }
    }
}
