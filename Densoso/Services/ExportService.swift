import CryptoKit
import DensosoDomain
import Foundation
import SwiftData

@MainActor
@Observable
final class ExportService {
    var lastExportDate: Date?
    var isExporting = false
    var lastError: String?

    private static let formatVersion = 6
    private static let supportedFormatVersions: Set<Int> = [2, 3, 4, 5, 6]
    private static let backupReadBatchSize = 64

    struct BackupDocument: Codable {
        let formatVersion: Int
        let checksum: String
        let payload: BackupPayload
    }

    struct BackupPayload: Codable {
        let exportedAt: Date
        let userProfile: UserProfileExport?
        let mealRecords: [MealRecordExport]
        let workoutRecords: [WorkoutRecordExport]
        let weightRecords: [WeightRecordExport]?
        let goalProfiles: [GoalProfileExport]?
        let dailyHealthSnapshots: [DailyHealthSnapshotExport]?
        let scheduleEvents: [ScheduleEventExport]?
        let dailyBriefs: [DailyBriefExport]?
        let weeklyBriefs: [WeeklyBriefExport]?
        let weeklyReports: [WeeklyReportExport]?
        let profileRevisions: [ProfileRevisionExport]?
        let dailyMetricsProjection: [DailyMetricsProjectionExport]?
        let dailyCheckIns: [DailyCheckInExport]?
        let userPreferences: [UserPreferenceExport]?
        let mealPortionPriors: [MealPortionPriorExport]?

        struct UserProfileExport: Codable {
            let name: String
            let biologicalSex: String
            let dateOfBirth: Date?
            let heightCm: Double
            let weightKg: Double
            let weightHistoryJSON: String
            let activityLevel: String
            let dailyDeficitTarget: Int
            let createdAt: Date
            let updatedAt: Date
            var profileNeedsCompletion: Bool? = nil
            var profileKey: String? = nil
        }

        struct MealRecordExport: Codable {
            let id: UUID
            let date: Date
            let mealType: String
            let totalCaloriesKcal: Int
            let proteinG: Double
            let fatG: Double
            let carbsG: Double
            let notes: String?
            let confidence: String
            let algorithmVersion: String
            let createdAt: Date
            let sourceActionKey: String?
            let energyLowKcal: Double?
            let energyLikelyKcal: Double?
            let energyHighKcal: Double?
            let proteinLowG: Double?
            let proteinLikelyG: Double?
            let proteinHighG: Double?
            let fatLowG: Double?
            let fatLikelyG: Double?
            let fatHighG: Double?
            let carbsLowG: Double?
            let carbsLikelyG: Double?
            let carbsHighG: Double?
            let evidenceData: Data?
            let dishes: [DishExport]

            private enum CodingKeys: String, CodingKey {
                case id, date, mealType, totalCaloriesKcal, proteinG, fatG, carbsG
                case notes, confidence, algorithmVersion, createdAt, sourceActionKey
                case energyLowKcal, energyLikelyKcal, energyHighKcal
                case proteinLowG, proteinLikelyG, proteinHighG
                case fatLowG, fatLikelyG, fatHighG
                case carbsLowG, carbsLikelyG, carbsHighG, evidenceData, dishes
            }

            init(
                id: UUID,
                date: Date,
                mealType: String,
                totalCaloriesKcal: Int,
                proteinG: Double,
                fatG: Double,
                carbsG: Double,
                notes: String?,
                confidence: String,
                algorithmVersion: String,
                createdAt: Date,
                sourceActionKey: String? = nil,
                energyLowKcal: Double? = nil,
                energyLikelyKcal: Double? = nil,
                energyHighKcal: Double? = nil,
                proteinLowG: Double? = nil,
                proteinLikelyG: Double? = nil,
                proteinHighG: Double? = nil,
                fatLowG: Double? = nil,
                fatLikelyG: Double? = nil,
                fatHighG: Double? = nil,
                carbsLowG: Double? = nil,
                carbsLikelyG: Double? = nil,
                carbsHighG: Double? = nil,
                evidenceData: Data? = nil,
                dishes: [DishExport]
            ) {
                self.id = id
                self.date = date
                self.mealType = mealType
                self.totalCaloriesKcal = totalCaloriesKcal
                self.proteinG = proteinG
                self.fatG = fatG
                self.carbsG = carbsG
                self.notes = notes
                self.confidence = confidence
                self.algorithmVersion = algorithmVersion
                self.createdAt = createdAt
                self.sourceActionKey = sourceActionKey
                self.energyLowKcal = energyLowKcal
                self.energyLikelyKcal = energyLikelyKcal
                self.energyHighKcal = energyHighKcal
                self.proteinLowG = proteinLowG
                self.proteinLikelyG = proteinLikelyG
                self.proteinHighG = proteinHighG
                self.fatLowG = fatLowG
                self.fatLikelyG = fatLikelyG
                self.fatHighG = fatHighG
                self.carbsLowG = carbsLowG
                self.carbsLikelyG = carbsLikelyG
                self.carbsHighG = carbsHighG
                self.evidenceData = evidenceData
                self.dishes = dishes
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(UUID.self, forKey: .id)
                date = try container.decode(Date.self, forKey: .date)
                mealType = try container.decode(String.self, forKey: .mealType)
                totalCaloriesKcal = try container.decode(Int.self, forKey: .totalCaloriesKcal)
                proteinG = try container.decode(Double.self, forKey: .proteinG)
                fatG = try container.decode(Double.self, forKey: .fatG)
                carbsG = try container.decode(Double.self, forKey: .carbsG)
                notes = try container.decodeIfPresent(String.self, forKey: .notes)
                confidence = try container.decode(String.self, forKey: .confidence)
                algorithmVersion = try container.decode(String.self, forKey: .algorithmVersion)
                createdAt = try container.decode(Date.self, forKey: .createdAt)
                sourceActionKey = try container.decodeIfPresent(String.self, forKey: .sourceActionKey)
                energyLowKcal = try container.decodeIfPresent(Double.self, forKey: .energyLowKcal)
                energyLikelyKcal = try container.decodeIfPresent(Double.self, forKey: .energyLikelyKcal)
                energyHighKcal = try container.decodeIfPresent(Double.self, forKey: .energyHighKcal)
                proteinLowG = try container.decodeIfPresent(Double.self, forKey: .proteinLowG)
                proteinLikelyG = try container.decodeIfPresent(Double.self, forKey: .proteinLikelyG)
                proteinHighG = try container.decodeIfPresent(Double.self, forKey: .proteinHighG)
                fatLowG = try container.decodeIfPresent(Double.self, forKey: .fatLowG)
                fatLikelyG = try container.decodeIfPresent(Double.self, forKey: .fatLikelyG)
                fatHighG = try container.decodeIfPresent(Double.self, forKey: .fatHighG)
                carbsLowG = try container.decodeIfPresent(Double.self, forKey: .carbsLowG)
                carbsLikelyG = try container.decodeIfPresent(Double.self, forKey: .carbsLikelyG)
                carbsHighG = try container.decodeIfPresent(Double.self, forKey: .carbsHighG)
                evidenceData = try container.decodeIfPresent(Data.self, forKey: .evidenceData)
                dishes = try container.decode([DishExport].self, forKey: .dishes)
            }
        }

        struct DishExport: Codable {
            let dishName: String
            let cookingMethod: String?
            let ingredientJSON: String
            let estimatedCaloriesKcal: Int
            let estimatedProteinG: Double
            let estimatedFatG: Double
            let estimatedCarbsG: Double
            let confidenceScore: Double
            let userCorrectionFactor: Double?
            let createdAt: Date
            let id: UUID?
            let energyLowKcal: Double?
            let energyLikelyKcal: Double?
            let energyHighKcal: Double?
            let proteinLowG: Double?
            let proteinLikelyG: Double?
            let proteinHighG: Double?
            let fatLowG: Double?
            let fatLikelyG: Double?
            let fatHighG: Double?
            let carbsLowG: Double?
            let carbsLikelyG: Double?
            let carbsHighG: Double?
            let portionLowG: Double?
            let portionLikelyG: Double?
            let portionHighG: Double?
            let evidenceData: Data?
            let algorithmVersion: String?

            init(
                dishName: String,
                cookingMethod: String?,
                ingredientJSON: String,
                estimatedCaloriesKcal: Int,
                estimatedProteinG: Double,
                estimatedFatG: Double,
                estimatedCarbsG: Double,
                confidenceScore: Double,
                userCorrectionFactor: Double?,
                createdAt: Date,
                id: UUID? = nil,
                energyLowKcal: Double? = nil,
                energyLikelyKcal: Double? = nil,
                energyHighKcal: Double? = nil,
                proteinLowG: Double? = nil,
                proteinLikelyG: Double? = nil,
                proteinHighG: Double? = nil,
                fatLowG: Double? = nil,
                fatLikelyG: Double? = nil,
                fatHighG: Double? = nil,
                carbsLowG: Double? = nil,
                carbsLikelyG: Double? = nil,
                carbsHighG: Double? = nil,
                portionLowG: Double? = nil,
                portionLikelyG: Double? = nil,
                portionHighG: Double? = nil,
                evidenceData: Data? = nil,
                algorithmVersion: String? = nil
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
                self.createdAt = createdAt
                self.id = id
                self.energyLowKcal = energyLowKcal
                self.energyLikelyKcal = energyLikelyKcal
                self.energyHighKcal = energyHighKcal
                self.proteinLowG = proteinLowG
                self.proteinLikelyG = proteinLikelyG
                self.proteinHighG = proteinHighG
                self.fatLowG = fatLowG
                self.fatLikelyG = fatLikelyG
                self.fatHighG = fatHighG
                self.carbsLowG = carbsLowG
                self.carbsLikelyG = carbsLikelyG
                self.carbsHighG = carbsHighG
                self.portionLowG = portionLowG
                self.portionLikelyG = portionLikelyG
                self.portionHighG = portionHighG
                self.evidenceData = evidenceData
                self.algorithmVersion = algorithmVersion
            }

            private enum CodingKeys: String, CodingKey {
                case dishName, cookingMethod, ingredientJSON, estimatedCaloriesKcal
                case estimatedProteinG, estimatedFatG, estimatedCarbsG, confidenceScore
                case userCorrectionFactor, createdAt, id, energyLowKcal, energyLikelyKcal
                case energyHighKcal, proteinLowG, proteinLikelyG, proteinHighG
                case fatLowG, fatLikelyG, fatHighG, carbsLowG, carbsLikelyG, carbsHighG
                case portionLowG, portionLikelyG, portionHighG, evidenceData, algorithmVersion
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                dishName = try container.decode(String.self, forKey: .dishName)
                cookingMethod = try container.decodeIfPresent(String.self, forKey: .cookingMethod)
                ingredientJSON = try container.decode(String.self, forKey: .ingredientJSON)
                estimatedCaloriesKcal = try container.decode(Int.self, forKey: .estimatedCaloriesKcal)
                estimatedProteinG = try container.decode(Double.self, forKey: .estimatedProteinG)
                estimatedFatG = try container.decode(Double.self, forKey: .estimatedFatG)
                estimatedCarbsG = try container.decode(Double.self, forKey: .estimatedCarbsG)
                confidenceScore = try container.decode(Double.self, forKey: .confidenceScore)
                userCorrectionFactor = try container.decodeIfPresent(Double.self, forKey: .userCorrectionFactor)
                createdAt = try container.decode(Date.self, forKey: .createdAt)
                id = try container.decodeIfPresent(UUID.self, forKey: .id)
                energyLowKcal = try container.decodeIfPresent(Double.self, forKey: .energyLowKcal)
                energyLikelyKcal = try container.decodeIfPresent(Double.self, forKey: .energyLikelyKcal)
                energyHighKcal = try container.decodeIfPresent(Double.self, forKey: .energyHighKcal)
                proteinLowG = try container.decodeIfPresent(Double.self, forKey: .proteinLowG)
                proteinLikelyG = try container.decodeIfPresent(Double.self, forKey: .proteinLikelyG)
                proteinHighG = try container.decodeIfPresent(Double.self, forKey: .proteinHighG)
                fatLowG = try container.decodeIfPresent(Double.self, forKey: .fatLowG)
                fatLikelyG = try container.decodeIfPresent(Double.self, forKey: .fatLikelyG)
                fatHighG = try container.decodeIfPresent(Double.self, forKey: .fatHighG)
                carbsLowG = try container.decodeIfPresent(Double.self, forKey: .carbsLowG)
                carbsLikelyG = try container.decodeIfPresent(Double.self, forKey: .carbsLikelyG)
                carbsHighG = try container.decodeIfPresent(Double.self, forKey: .carbsHighG)
                portionLowG = try container.decodeIfPresent(Double.self, forKey: .portionLowG)
                portionLikelyG = try container.decodeIfPresent(Double.self, forKey: .portionLikelyG)
                portionHighG = try container.decodeIfPresent(Double.self, forKey: .portionHighG)
                evidenceData = try container.decodeIfPresent(Data.self, forKey: .evidenceData)
                algorithmVersion = try container.decodeIfPresent(String.self, forKey: .algorithmVersion)
            }
        }

        struct WorkoutRecordExport: Codable {
            let id: UUID
            let date: Date
            let type: String
            let durationMinutes: Int
            let estimatedCaloriesBurned: Int
            let intensity: String
            let notes: String?
            let createdAt: Date
            let updatedAt: Date?
            let healthKitUUID: UUID?
            let logicalSessionID: UUID?
            let workoutOrigin: String?
            let energySource: String?
            let sourceBundleIdentifier: String?
            let sourceVersion: String?
            let sourceRevision: String?
            let deviceName: String?
            let deviceModel: String?
            let dataQuality: String?
            let routeStatus: String?
            let routePointCount: Int?
        }

        struct WeightRecordExport: Codable {
            let id: UUID
            let sourceActionKey: String
            let measuredAt: Date
            let kilograms: Double
            let source: String
            let algorithmVersion: String
            let createdAt: Date
            var confidence: Double? = nil
            var healthKitSyncIdentifier: String? = nil
        }

        struct ProfileRevisionExport: Codable {
            let id: UUID
            let profileKey: String
            let effectiveFrom: Date
            let dateOfBirth: Date?
            let biologicalSex: String
            let heightCm: Double
            let weightKg: Double?
            let activityLevel: String
            let source: String
            let createdAt: Date
        }

        struct DailyCheckInExport: Codable {
            let id: UUID
            let sourceActionKey: String
            let occurredAt: Date
            let energyRaw: String
            let stressRaw: String
            let subjectiveSleepRaw: String
            let note: String?
            let sourceRaw: String
            let createdAt: Date
        }

        struct UserPreferenceExport: Codable {
            let id: UUID
            let sourceActionKey: String
            let categoryRaw: String
            let statement: String
            let sourceRaw: String
            let createdAt: Date
        }

        struct MealPortionPriorExport: Codable {
            let id: UUID
            let priorKey: String
            let foodID: String?
            let foodName: String
            let unit: String
            let p10Grams: Double
            let p50Grams: Double
            let p90Grams: Double
            let sourceActionKey: String?
            let createdAt: Date
            let updatedAt: Date
        }

        struct DailyMetricsProjectionExport: Codable {
            let date: Date
            let projectionVersion: String
            let sourceFingerprint: String
            let energyQuality: String
            let requiresRecompute: Bool
        }

        struct GoalProfileExport: Codable {
            let id: UUID
            let profileKey: String
            let targetWeightKilograms: Double?
            let dailyDeficitKcal: Int?
            let dailyProteinGrams: Double?
            let effectiveFrom: Date
            let updatedAt: Date
        }

        struct DailyHealthSnapshotExport: Codable {
            let id: UUID
            let dayKey: String
            let timezoneID: String
            let payloadData: Data
            let snapshotHash: String
            let algorithmVersion: String
            let createdAt: Date
        }

        struct ScheduleEventExport: Codable {
            let date: Date
            let title: String
            let notes: String?
            let startTime: Date
            let endTime: Date?
            let createdAt: Date
        }

        struct DailyBriefExport: Codable {
            let id: UUID
            let cacheKey: String
            let dayKey: String
            let snapshotHash: String
            let algorithmVersion: String
            let payloadData: Data
            let generatedAt: Date
        }

        struct WeeklyBriefExport: Codable {
            let id: UUID
            let cacheKey: String
            let weekKey: String
            let snapshotHash: String
            let algorithmVersion: String
            let payloadData: Data
            let generatedAt: Date
        }

        struct WeeklyReportExport: Codable {
            let weekStartDate: Date
            let weekEndDate: Date
            let totalDeficitKcal: Int
            let avgDailyDeficitKcal: Double
            let projectedWeightLossKg: Double
            let avgProteinG: Double
            let avgFatG: Double
            let avgCarbsG: Double
            let bestDay: Date?
            let worstDay: Date?
            let mealsCount: Int
            let workoutsCount: Int
            let compliance: Double
            let generatedAt: Date
        }
    }

    enum BackupError: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case checksumMismatch
        case invalidDailyCheckIn
        case invalidUserPreference
        case invalidMealPortionPrior
        case invalidTrainingPlan

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version): "Unsupported backup version: \(version)"
            case .checksumMismatch: "The backup file did not pass its integrity check."
            case .invalidDailyCheckIn: "The backup contains an invalid user-reported daily check-in."
            case .invalidUserPreference: "The backup contains an invalid user-reported preference."
            case .invalidMealPortionPrior: "The backup contains an invalid personal meal portion prior."
            case .invalidTrainingPlan: "The backup contains an invalid confirmed training plan."
            }
        }
    }

    func exportJSON(context: ModelContext) async throws -> URL {
        isExporting = true
        defer { isExporting = false }

        let payload = try makePayload(context: context)
        let document = BackupDocument(
            formatVersion: Self.formatVersion,
            checksum: try checksum(for: payload),
            payload: payload
        )
        let data = try encoder.encode(document)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso_backup_\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )

        lastExportDate = Date()
        return url
    }

    /// Validates the entire file before replacing local data, then reprojects derived metrics.
    func restoreJSON(url: URL, context: ModelContext) async throws -> ImportSummary {
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(BackupDocument.self, from: data)
        guard Self.supportedFormatVersions.contains(document.formatVersion) else {
            throw BackupError.unsupportedVersion(document.formatVersion)
        }
        guard try checksum(for: document.payload) == document.checksum else {
            throw BackupError.checksumMismatch
        }
        try validateTrainingPlanBackupEvents(document.payload.scheduleEvents)
        let profileSource = document.payload.userProfile
        let restoredBirthDate: Date?
        if let profileSource,
           let dateOfBirth = profileSource.dateOfBirth,
           dateOfBirth.timeIntervalSince1970 != 0,
           dateOfBirth <= profileSource.updatedAt {
            restoredBirthDate = dateOfBirth
        } else {
            restoredBirthDate = nil
        }
        let restoredProfileKey = profileSource?.profileKey ?? "primary"
        let dailyCheckIns = try (document.payload.dailyCheckIns ?? []).map { source in
            guard source.sourceRaw == "userReported",
                  let energy = UserReportedEnergy(rawValue: source.energyRaw),
                  let stress = UserReportedStress(rawValue: source.stressRaw),
                  let sleep = SubjectiveSleepQuality(rawValue: source.subjectiveSleepRaw),
                  !source.sourceActionKey.isEmpty else {
                throw BackupError.invalidDailyCheckIn
            }
            do {
                _ = try ActionPayload.dailyCheckIn(DailyCheckIn(
                    occurredAt: source.occurredAt,
                    energy: energy,
                    stress: stress,
                    subjectiveSleep: sleep,
                    note: source.note
                )).canonicalData()
            } catch {
                throw BackupError.invalidDailyCheckIn
            }
            return source
        }
        let userPreferences = try (document.payload.userPreferences ?? []).map { source in
            let statement = source.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard source.sourceRaw == UserPreferenceSource.userReported.rawValue,
                  let category = UserPreferenceCategory(rawValue: source.categoryRaw),
                  !source.sourceActionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !statement.isEmpty,
                  statement.count <= 500 else {
                throw BackupError.invalidUserPreference
            }
            do {
                _ = try ActionPayload.userPreference(UserPreference(
                    id: source.id,
                    category: category,
                    statement: statement,
                    createdAt: source.createdAt
                )).canonicalData()
            } catch {
                throw BackupError.invalidUserPreference
            }
            return BackupPayload.UserPreferenceExport(
                id: source.id,
                sourceActionKey: source.sourceActionKey,
                categoryRaw: category.rawValue,
                statement: statement,
                sourceRaw: UserPreferenceSource.userReported.rawValue,
                createdAt: source.createdAt
            )
        }
        var priorKeys = Set<String>()
        var priorIDs = Set<UUID>()
        let mealPortionPriors = try (document.payload.mealPortionPriors ?? []).map { source in
            let foodName = source.foodName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !foodName.isEmpty,
                  foodName.count <= 120,
                  let unit = MealPortionPriorCorrection.normalizeSupportedUnit(source.unit),
                  let expectedKey = MealPortionPriorStorageKey.make(
                    foodID: source.foodID,
                    foodName: foodName,
                    unit: unit
                  ),
                  source.priorKey == expectedKey,
                  source.p10Grams.isFinite,
                  source.p50Grams.isFinite,
                  source.p90Grams.isFinite,
                  (0.1...5_000).contains(source.p10Grams),
                  source.p10Grams <= source.p50Grams,
                  source.p50Grams <= source.p90Grams,
                  source.p90Grams <= 5_000,
                  priorKeys.insert(source.priorKey).inserted,
                  priorIDs.insert(source.id).inserted else {
                throw BackupError.invalidMealPortionPrior
            }
            return BackupPayload.MealPortionPriorExport(
                id: source.id,
                priorKey: expectedKey,
                foodID: source.foodID,
                foodName: foodName,
                unit: unit,
                p10Grams: source.p10Grams,
                p50Grams: source.p50Grams,
                p90Grams: source.p90Grams,
                sourceActionKey: source.sourceActionKey,
                createdAt: source.createdAt,
                updatedAt: source.updatedAt
            )
        }
        let legacyWeightEntries: [UserProfile.WeightEntry] = profileSource.flatMap { source in
            guard let data = source.weightHistoryJSON.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([UserProfile.WeightEntry].self, from: data)
        } ?? []

        do {
            // Request budgets are deliberately not part of backups: their resumable
            // transcript is not exported. Remove unfinished request fragments and all
            // request ledger rows so restore cannot leave orphan resumable work.
            let requestRecords = try fetchAllRecords(
                of: AgentRequestRecord.self,
                in: context,
                sortedBy: [SortDescriptor(\AgentRequestRecord.requestID)]
            )
            let unfinishedRequestIDs = Set(
                requestRecords
                    .filter { $0.stateRaw != AgentRequestState.completed.rawValue }
                    .map(\.requestID)
            )
            if !unfinishedRequestIDs.isEmpty {
                let messages = try fetchAllRecords(
                    of: MessageRecord.self,
                    in: context,
                    sortedBy: [
                        SortDescriptor(\MessageRecord.ordinal),
                        SortDescriptor(\MessageRecord.id),
                    ]
                )
                for message in messages {
                    if let requestID = message.requestID, unfinishedRequestIDs.contains(requestID) {
                        context.delete(message)
                    }
                }
            }
            for request in requestRecords { context.delete(request) }

            try context.delete(model: UserProfile.self)
            try context.delete(model: ProfileRevisionRecord.self)
            try context.delete(model: MealRecord.self)
            try context.delete(model: WorkoutRecord.self)
            try context.delete(model: WeightRecord.self)
            try context.delete(model: GoalProfileRecord.self)
            try context.delete(model: DailyCheckInRecord.self)
            try context.delete(model: UserPreferenceRecord.self)
            try context.delete(model: PersonalMealPortionPriorRecord.self)
            try context.delete(model: DailyHealthSnapshotRecord.self)
            try context.delete(model: DailyBriefRecord.self)
            try context.delete(model: WeeklyBriefRecord.self)
            try context.delete(model: ScheduleEvent.self)
            try context.delete(model: DailyMetrics.self)
            try context.delete(model: WeeklyReport.self)
            try context.delete(model: HealthSyncOutboxEntry.self)
            try context.delete(model: HealthKitImportCursor.self)

            if let source = profileSource {
                let profile = UserProfile(
                    name: source.name,
                    biologicalSex: source.biologicalSex,
                    dateOfBirth: restoredBirthDate,
                    heightCm: source.heightCm,
                    weightKg: source.weightKg,
                    activityLevel: source.activityLevel,
                    dailyDeficitTarget: source.dailyDeficitTarget
                )
                profile.weightHistoryJSON = source.weightHistoryJSON
                profile.createdAt = source.createdAt
                profile.updatedAt = source.updatedAt
                profile.profileNeedsCompletion = restoredBirthDate == nil || (source.profileNeedsCompletion ?? false)
                profile.profileKey = restoredProfileKey
                context.insert(profile)
            }

            let sourceRevisions = document.payload.profileRevisions ?? []
            for source in sourceRevisions {
                context.insert(
                    ProfileRevisionRecord(
                        id: source.id,
                        profileKey: source.profileKey,
                        effectiveFrom: source.effectiveFrom,
                        dateOfBirth: source.dateOfBirth,
                        biologicalSex: source.biologicalSex,
                        heightCm: source.heightCm,
                        weightKg: source.weightKg,
                        activityLevel: source.activityLevel,
                        source: source.source,
                        createdAt: source.createdAt
                    )
                )
            }
            for source in dailyCheckIns {
                context.insert(DailyCheckInRecord(
                    id: source.id,
                    sourceActionKey: source.sourceActionKey,
                    occurredAt: source.occurredAt,
                    energyRaw: source.energyRaw,
                    stressRaw: source.stressRaw,
                    subjectiveSleepRaw: source.subjectiveSleepRaw,
                    note: source.note,
                    sourceRaw: source.sourceRaw,
                    createdAt: source.createdAt
                ))
            }
            for source in userPreferences {
                context.insert(UserPreferenceRecord(
                    id: source.id,
                    sourceActionKey: source.sourceActionKey,
                    categoryRaw: source.categoryRaw,
                    statement: source.statement,
                    sourceRaw: source.sourceRaw,
                    createdAt: source.createdAt
                ))
            }
            for source in mealPortionPriors {
                context.insert(PersonalMealPortionPriorRecord(
                    id: source.id,
                    priorKey: source.priorKey,
                    foodID: source.foodID,
                    foodName: source.foodName,
                    unit: source.unit,
                    p10Grams: source.p10Grams,
                    p50Grams: source.p50Grams,
                    p90Grams: source.p90Grams,
                    sourceActionKey: source.sourceActionKey,
                    createdAt: source.createdAt,
                    updatedAt: source.updatedAt
                ))
            }
            if sourceRevisions.isEmpty, let source = profileSource {
                context.insert(
                    ProfileRevisionRecord(
                        profileKey: restoredProfileKey,
                        effectiveFrom: source.updatedAt,
                        dateOfBirth: restoredBirthDate,
                        biologicalSex: source.biologicalSex,
                        heightCm: source.heightCm,
                        weightKg: source.weightKg,
                        activityLevel: source.activityLevel,
                        source: "legacyMigration",
                        createdAt: source.updatedAt
                    )
                )
            }

            let snapshots = document.payload.dailyHealthSnapshots ?? []
            let snapshotDecoder = JSONDecoder()
            snapshotDecoder.dateDecodingStrategy = .millisecondsSince1970
            let snapshotDates = snapshots.compactMap {
                try? snapshotDecoder.decode(DailyHealthSnapshot.self, from: $0.payloadData).dayStart
            }
            let weights = document.payload.weightRecords ?? []
            let affectedDays = Set(
                document.payload.mealRecords.map(\.date)
                    + document.payload.workoutRecords.map(\.date)
                    + weights.map(\.measuredAt)
                    + legacyWeightEntries.map(\.date)
                    + snapshotDates
            )
            for source in document.payload.mealRecords {
                let meal = MealRecord(
                    date: source.date,
                    mealType: source.mealType,
                    totalCaloriesKcal: source.totalCaloriesKcal,
                    proteinG: source.proteinG,
                    fatG: source.fatG,
                    carbsG: source.carbsG,
                    notes: source.notes,
                    confidence: source.confidence,
                    algorithmVersion: source.algorithmVersion,
                    sourceActionKey: source.sourceActionKey,
                    energyLowKcal: source.energyLowKcal,
                    energyLikelyKcal: source.energyLikelyKcal,
                    energyHighKcal: source.energyHighKcal,
                    proteinLowG: source.proteinLowG,
                    proteinLikelyG: source.proteinLikelyG,
                    proteinHighG: source.proteinHighG,
                    fatLowG: source.fatLowG,
                    fatLikelyG: source.fatLikelyG,
                    fatHighG: source.fatHighG,
                    carbsLowG: source.carbsLowG,
                    carbsLikelyG: source.carbsLikelyG,
                    carbsHighG: source.carbsHighG,
                    evidenceData: source.evidenceData
                )
                meal.id = source.id
                meal.createdAt = source.createdAt
                meal.dishes = source.dishes.map { dishSource in
                    let dish = DishEntry(
                        id: dishSource.id ?? UUID(),
                        dishName: dishSource.dishName,
                        cookingMethod: dishSource.cookingMethod,
                        ingredientJSON: dishSource.ingredientJSON,
                        estimatedCaloriesKcal: dishSource.estimatedCaloriesKcal,
                        estimatedProteinG: dishSource.estimatedProteinG,
                        estimatedFatG: dishSource.estimatedFatG,
                        estimatedCarbsG: dishSource.estimatedCarbsG,
                        confidenceScore: dishSource.confidenceScore,
                        userCorrectionFactor: dishSource.userCorrectionFactor,
                        energyLowKcal: dishSource.energyLowKcal,
                        energyLikelyKcal: dishSource.energyLikelyKcal,
                        energyHighKcal: dishSource.energyHighKcal,
                        proteinLowG: dishSource.proteinLowG,
                        proteinLikelyG: dishSource.proteinLikelyG,
                        proteinHighG: dishSource.proteinHighG,
                        fatLowG: dishSource.fatLowG,
                        fatLikelyG: dishSource.fatLikelyG,
                        fatHighG: dishSource.fatHighG,
                        carbsLowG: dishSource.carbsLowG,
                        carbsLikelyG: dishSource.carbsLikelyG,
                        carbsHighG: dishSource.carbsHighG,
                        portionLowG: dishSource.portionLowG,
                        portionLikelyG: dishSource.portionLikelyG,
                        portionHighG: dishSource.portionHighG,
                        evidenceData: dishSource.evidenceData,
                        algorithmVersion: dishSource.algorithmVersion ?? source.algorithmVersion
                    )
                    dish.createdAt = dishSource.createdAt
                    return dish
                }
                context.insert(meal)
            }

            for source in document.payload.workoutRecords {
                let workout = WorkoutRecord(
                    date: source.date,
                    type: source.type,
                    durationMinutes: source.durationMinutes,
                    estimatedCaloriesBurned: source.estimatedCaloriesBurned,
                    intensity: source.intensity,
                    notes: source.notes,
                    healthKitUUID: source.healthKitUUID,
                    logicalSessionID: source.logicalSessionID,
                    workoutOrigin: source.workoutOrigin ?? "userEntered",
                    energySource: source.energySource,
                    sourceBundleIdentifier: source.sourceBundleIdentifier,
                    sourceVersion: source.sourceVersion,
                    sourceRevision: source.sourceRevision,
                    deviceName: source.deviceName,
                    deviceModel: source.deviceModel,
                    dataQuality: source.dataQuality ?? "complete",
                    routeStatus: source.routeStatus ?? "unavailable",
                    routePointCount: source.routePointCount
                )
                workout.id = source.id
                workout.createdAt = source.createdAt
                workout.updatedAt = source.updatedAt ?? source.createdAt
                context.insert(workout)
            }

            var restoredWeights: [WeightRecord] = []
            for source in weights {
                let weight = WeightRecord(
                    id: source.id,
                    sourceActionKey: source.sourceActionKey,
                    measuredAt: source.measuredAt,
                    kilograms: source.kilograms,
                    source: source.source,
                    algorithmVersion: source.algorithmVersion,
                    confidence: source.confidence ?? 0.9,
                    healthKitSyncIdentifier: source.healthKitSyncIdentifier
                )
                weight.createdAt = source.createdAt
                context.insert(weight)
                restoredWeights.append(weight)
            }
            for (index, entry) in legacyWeightEntries.enumerated()
            where entry.date.timeIntervalSince1970.isFinite && entry.kg.isFinite && entry.kg > 0 {
                guard !restoredWeights.contains(where: {
                    $0.measuredAt == entry.date && $0.kilograms == entry.kg
                }) else {
                    continue
                }
                let weight = WeightRecord(
                    sourceActionKey: "backup-profile-weight-\(index)-\(UUID().uuidString.lowercased())",
                    measuredAt: entry.date,
                    kilograms: entry.kg,
                    source: "densoso",
                    algorithmVersion: "v4-backup-migration",
                    confidence: 0.75
                )
                context.insert(weight)
                restoredWeights.append(weight)
            }

            for source in document.payload.goalProfiles ?? [] {
                let goal = GoalProfileRecord(
                    id: source.id,
                    profileKey: source.profileKey,
                    targetWeightKilograms: source.targetWeightKilograms,
                    dailyDeficitKcal: source.dailyDeficitKcal,
                    dailyProteinGrams: source.dailyProteinGrams,
                    effectiveFrom: source.effectiveFrom
                )
                goal.updatedAt = source.updatedAt
                context.insert(goal)
            }

            for source in snapshots {
                let snapshot = DailyHealthSnapshotRecord(
                    id: source.id,
                    dayKey: source.dayKey,
                    timezoneID: source.timezoneID,
                    payloadData: source.payloadData,
                    snapshotHash: source.snapshotHash,
                    algorithmVersion: source.algorithmVersion
                )
                snapshot.createdAt = source.createdAt
                context.insert(snapshot)
            }

            for source in document.payload.scheduleEvents ?? [] {
                let event = ScheduleEvent(
                    date: source.date,
                    title: source.title,
                    notes: source.notes,
                    startTime: source.startTime,
                    endTime: source.endTime
                )
                event.createdAt = source.createdAt
                context.insert(event)
            }

            for date in affectedDays {
                try DailyMetricsProjector.reproject(on: date, in: context)
            }

            for source in document.payload.dailyBriefs ?? [] {
                let brief = DailyBriefRecord(
                    id: source.id,
                    cacheKey: source.cacheKey,
                    dayKey: source.dayKey,
                    snapshotHash: source.snapshotHash,
                    algorithmVersion: source.algorithmVersion,
                    payloadData: source.payloadData
                )
                brief.generatedAt = source.generatedAt
                context.insert(brief)
            }
            for source in document.payload.weeklyBriefs ?? [] {
                let brief = WeeklyBriefRecord(
                    id: source.id,
                    cacheKey: source.cacheKey,
                    weekKey: source.weekKey,
                    snapshotHash: source.snapshotHash,
                    algorithmVersion: source.algorithmVersion,
                    payloadData: source.payloadData
                )
                brief.generatedAt = source.generatedAt
                context.insert(brief)
            }
            for source in document.payload.weeklyReports ?? [] {
                let report = WeeklyReport(
                    weekStartDate: source.weekStartDate,
                    weekEndDate: source.weekEndDate,
                    totalDeficitKcal: source.totalDeficitKcal,
                    avgDailyDeficitKcal: source.avgDailyDeficitKcal,
                    projectedWeightLossKg: source.projectedWeightLossKg,
                    avgProteinG: source.avgProteinG,
                    avgFatG: source.avgFatG,
                    avgCarbsG: source.avgCarbsG,
                    bestDay: source.bestDay,
                    worstDay: source.worstDay,
                    mealsCount: source.mealsCount,
                    workoutsCount: source.workoutsCount,
                    compliance: source.compliance
                )
                report.generatedAt = source.generatedAt
                context.insert(report)
            }
            try invalidateCloudHealthPoliciesForRestore(in: context)
            try context.save()

            return ImportSummary(
                meals: document.payload.mealRecords.count,
                workouts: document.payload.workoutRecords.count,
                dailyMetrics: affectedDays.count,
                weights: weights.count,
                healthDays: snapshots.count,
                dailyCheckIns: dailyCheckIns.count,
                userPreferences: userPreferences.count,
                mealPortionPriors: mealPortionPriors.count,
                scheduledPlans: (document.payload.scheduleEvents ?? []).filter {
                    ConfirmedWorkoutPlanEntry.decode(notes: $0.notes) != nil
                        || ConfirmedTrainingPlanEntry.decode(notes: $0.notes) != nil
                }.count
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    struct ImportSummary {
        let meals: Int
        let workouts: Int
        let dailyMetrics: Int
        let weights: Int
        let healthDays: Int
        let dailyCheckIns: Int
        let userPreferences: Int
        let mealPortionPriors: Int
        let scheduledPlans: Int
    }

    /// Restoring a backup replaces the data a previously confirmed cloud-health
    /// policy was meant to describe. Revoke that authorization in the same
    /// ModelContext transaction as the restored data, so a failed restore cannot
    /// leave either half of the replacement committed.
    private func invalidateCloudHealthPoliciesForRestore(in context: ModelContext) throws {
        let healthPolicyClasses = CloudHealthContextPolicy.dataClasses + [.conversationHistory]
        let relevantConsentKeysByProvider = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { provider in
            (
                provider,
                Set(healthPolicyClasses.map { "provider|\(provider.rawValue)|\($0.rawValue)" })
            )
        })
        let consentRecords = try context.fetch(FetchDescriptor<ConsentRecord>())
        let policyRecords = try context.fetch(FetchDescriptor<CloudHealthContextPolicyRecord>())
        let now = Date()

        for provider in ProviderID.allCases {
            let policyKey = "cloud-health-context-policy|\(provider.rawValue)"
            let policyRecord = policyRecords.first { $0.policyKey == policyKey }
            let relevantKeys = relevantConsentKeysByProvider[provider] ?? []
            let providerConsents = consentRecords.filter { relevantKeys.contains($0.consentKey) }
            let hasPersistedAuthorization = providerConsents.contains { $0.granted }
            let hasPolicyAuthorization = policyRecord.map {
                $0.stateRaw == CloudHealthPolicyState.active.rawValue
                    || $0.stateRaw == CloudHealthPolicyState.draft.rawValue
                    || !$0.allowedClassesRaw.isEmpty
            } ?? false

            guard hasPersistedAuthorization || hasPolicyAuthorization else { continue }

            for record in providerConsents {
                record.granted = false
                record.policyVersion = record.kind == ProviderDataClass.conversationHistory.rawValue
                    ? "cloud-conversation-history-v1"
                    : "cloud-health-context-v1"
                record.decidedAt = now
                record.revokedAt = now
            }

            let priorRevision = max(policyRecord?.revision ?? 0, 0)
            let nextRevision = priorRevision == Int.max ? Int.max : priorRevision + 1
            let policyID = policyRecord?.policyID
                ?? CloudHealthContextPolicySnapshot.unconfigured(provider: provider).policyID
            let createdAt = policyRecord?.createdAt ?? now
            let snapshot = CloudHealthContextPolicySnapshot.make(
                provider: provider,
                policyID: policyID,
                revision: nextRevision,
                state: .needsReconfirmation,
                allowedClasses: [],
                createdAt: createdAt,
                updatedAt: now,
                confirmedAt: nil,
                changeSource: .backupRestore
            )

            if let policyRecord {
                policyRecord.schemaVersion = snapshot.schemaVersion
                policyRecord.policyID = snapshot.policyID
                policyRecord.providerRaw = snapshot.provider.rawValue
                policyRecord.revision = snapshot.revision
                policyRecord.stateRaw = snapshot.state.rawValue
                policyRecord.allowedClassesRaw = ""
                policyRecord.createdAt = snapshot.createdAt
                policyRecord.updatedAt = snapshot.updatedAt
                policyRecord.confirmedAt = snapshot.confirmedAt
                policyRecord.policyHash = snapshot.policyHash
                policyRecord.changeSourceRaw = snapshot.changeSource.rawValue
            } else {
                context.insert(CloudHealthContextPolicyRecord(
                    policyKey: policyKey,
                    schemaVersion: snapshot.schemaVersion,
                    policyID: snapshot.policyID,
                    providerRaw: snapshot.provider.rawValue,
                    revision: snapshot.revision,
                    stateRaw: snapshot.state.rawValue,
                    allowedClassesRaw: "",
                    createdAt: snapshot.createdAt,
                    updatedAt: snapshot.updatedAt,
                    confirmedAt: snapshot.confirmedAt,
                    policyHash: snapshot.policyHash,
                    changeSourceRaw: snapshot.changeSource.rawValue
                ))
            }
        }
    }

    func validateTrainingPlanBackupEvents(_ events: [BackupPayload.ScheduleEventExport]?) throws {
        for event in events ?? [] {
            guard let notes = event.notes,
                  notes.hasPrefix(ConfirmedTrainingPlanEntry.notesPrefix) else {
                continue
            }
            guard let entry = ConfirmedTrainingPlanEntry.decode(notes: notes),
                  entry.draft.validationError == nil else {
                throw BackupError.invalidTrainingPlan
            }
        }
    }

    private func makePayload(context: ModelContext) throws -> BackupPayload {
        var profileDescriptor = FetchDescriptor<UserProfile>()
        profileDescriptor.fetchLimit = 1
        let profile = try context.fetch(profileDescriptor).first
        let profileRevisions = try fetchAllRecords(
            of: ProfileRevisionRecord.self,
            in: context,
            sortedBy: [
                SortDescriptor(\ProfileRevisionRecord.effectiveFrom),
                SortDescriptor(\ProfileRevisionRecord.id),
            ]
        )
            .sorted { $0.effectiveFrom == $1.effectiveFrom ? $0.id.uuidString < $1.id.uuidString : $0.effectiveFrom < $1.effectiveFrom }
        let meals = try fetchAllRecords(
            of: MealRecord.self,
            in: context,
            sortedBy: [SortDescriptor(\MealRecord.date), SortDescriptor(\MealRecord.id)]
        )
            .sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        let workouts = try fetchAllRecords(
            of: WorkoutRecord.self,
            in: context,
            sortedBy: [SortDescriptor(\WorkoutRecord.date), SortDescriptor(\WorkoutRecord.id)]
        )
            .sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        let weights = try fetchAllRecords(
            of: WeightRecord.self,
            in: context,
            sortedBy: [SortDescriptor(\WeightRecord.measuredAt), SortDescriptor(\WeightRecord.id)]
        )
            .sorted { $0.measuredAt == $1.measuredAt ? $0.id.uuidString < $1.id.uuidString : $0.measuredAt < $1.measuredAt }
        let goals = try fetchAllRecords(
            of: GoalProfileRecord.self,
            in: context,
            sortedBy: [SortDescriptor(\GoalProfileRecord.effectiveFrom), SortDescriptor(\GoalProfileRecord.id)]
        )
            .sorted { $0.effectiveFrom < $1.effectiveFrom }
        let dailyCheckIns = try fetchAllRecords(
            of: DailyCheckInRecord.self,
            in: context,
            sortedBy: [SortDescriptor(\DailyCheckInRecord.occurredAt), SortDescriptor(\DailyCheckInRecord.id)]
        )
            .sorted {
                $0.occurredAt == $1.occurredAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.occurredAt < $1.occurredAt
            }
        let userPreferences = try fetchAllRecords(
            of: UserPreferenceRecord.self,
            in: context,
            sortedBy: [SortDescriptor(\UserPreferenceRecord.createdAt), SortDescriptor(\UserPreferenceRecord.id)]
        )
            .sorted {
                $0.createdAt == $1.createdAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.createdAt < $1.createdAt
            }
        let mealPortionPriors = try fetchAllRecords(
            of: PersonalMealPortionPriorRecord.self,
            in: context,
            sortedBy: [
                SortDescriptor(\PersonalMealPortionPriorRecord.foodName),
                SortDescriptor(\PersonalMealPortionPriorRecord.unit),
            ]
        ).sorted {
            $0.priorKey < $1.priorKey
        }
        let healthSnapshots = try fetchAllRecords(
            of: DailyHealthSnapshotRecord.self,
            in: context,
            sortedBy: [SortDescriptor(\DailyHealthSnapshotRecord.dayKey)]
        )
            .sorted { $0.dayKey < $1.dayKey }
        let scheduleEvents = try fetchAllRecords(
            of: ScheduleEvent.self,
            in: context,
            sortedBy: [
                SortDescriptor(\ScheduleEvent.startTime),
                SortDescriptor(\ScheduleEvent.title),
                SortDescriptor(\ScheduleEvent.createdAt),
                SortDescriptor(\ScheduleEvent.notes),
            ]
        )
            .sorted { $0.startTime == $1.startTime ? $0.title < $1.title : $0.startTime < $1.startTime }
        let dailyBriefs = try fetchAllRecords(
            of: DailyBriefRecord.self,
            in: context,
            sortedBy: [SortDescriptor(\DailyBriefRecord.dayKey)]
        )
            .sorted { $0.dayKey < $1.dayKey }
        let weeklyBriefs = try fetchAllRecords(
            of: WeeklyBriefRecord.self,
            in: context,
            sortedBy: [SortDescriptor(\WeeklyBriefRecord.weekKey)]
        )
            .sorted { $0.weekKey < $1.weekKey }
        let weeklyReports = try fetchAllRecords(
            of: WeeklyReport.self,
            in: context,
            sortedBy: [SortDescriptor(\WeeklyReport.weekStartDate)]
        )
            .sorted { $0.weekStartDate < $1.weekStartDate }
        let dailyMetrics = try fetchAllRecords(
            of: DailyMetrics.self,
            in: context,
            sortedBy: [SortDescriptor(\DailyMetrics.date)]
        )
            .sorted { $0.date < $1.date }

        return BackupPayload(
            exportedAt: Date(),
            userProfile: profile.map { source in
                .init(
                    name: source.name,
                    biologicalSex: source.biologicalSex,
                    dateOfBirth: source.dateOfBirth,
                    heightCm: source.heightCm,
                    weightKg: source.weightKg,
                    weightHistoryJSON: source.weightHistoryJSON,
                    activityLevel: source.activityLevel,
                    dailyDeficitTarget: source.dailyDeficitTarget,
                    createdAt: source.createdAt,
                    updatedAt: source.updatedAt,
                    profileNeedsCompletion: source.profileNeedsCompletion,
                    profileKey: source.profileKey
                )
            },
            mealRecords: meals.map { source in
                .init(
                    id: source.id,
                    date: source.date,
                    mealType: source.mealType,
                    totalCaloriesKcal: source.totalCaloriesKcal,
                    proteinG: source.proteinG,
                    fatG: source.fatG,
                    carbsG: source.carbsG,
                    notes: source.notes,
                    confidence: source.confidence,
                    algorithmVersion: source.algorithmVersion,
                    createdAt: source.createdAt,
                    sourceActionKey: source.sourceActionKey,
                    energyLowKcal: source.energyLowKcal,
                    energyLikelyKcal: source.energyLikelyKcal,
                    energyHighKcal: source.energyHighKcal,
                    proteinLowG: source.proteinLowG,
                    proteinLikelyG: source.proteinLikelyG,
                    proteinHighG: source.proteinHighG,
                    fatLowG: source.fatLowG,
                    fatLikelyG: source.fatLikelyG,
                    fatHighG: source.fatHighG,
                    carbsLowG: source.carbsLowG,
                    carbsLikelyG: source.carbsLikelyG,
                    carbsHighG: source.carbsHighG,
                    evidenceData: source.evidenceData,
                    dishes: source.dishes.map { dish in
                        .init(
                            dishName: dish.dishName,
                            cookingMethod: dish.cookingMethod,
                            ingredientJSON: dish.ingredientJSON,
                            estimatedCaloriesKcal: dish.estimatedCaloriesKcal,
                            estimatedProteinG: dish.estimatedProteinG,
                            estimatedFatG: dish.estimatedFatG,
                            estimatedCarbsG: dish.estimatedCarbsG,
                            confidenceScore: dish.confidenceScore,
                            userCorrectionFactor: dish.userCorrectionFactor,
                            createdAt: dish.createdAt,
                            id: dish.id,
                            energyLowKcal: dish.energyLowKcal,
                            energyLikelyKcal: dish.energyLikelyKcal,
                            energyHighKcal: dish.energyHighKcal,
                            proteinLowG: dish.proteinLowG,
                            proteinLikelyG: dish.proteinLikelyG,
                            proteinHighG: dish.proteinHighG,
                            fatLowG: dish.fatLowG,
                            fatLikelyG: dish.fatLikelyG,
                            fatHighG: dish.fatHighG,
                            carbsLowG: dish.carbsLowG,
                            carbsLikelyG: dish.carbsLikelyG,
                            carbsHighG: dish.carbsHighG,
                            portionLowG: dish.portionLowG,
                            portionLikelyG: dish.portionLikelyG,
                            portionHighG: dish.portionHighG,
                            evidenceData: dish.evidenceData,
                            algorithmVersion: dish.algorithmVersion
                        )
                    }
                )
            },
            workoutRecords: workouts.map { source in
                .init(
                    id: source.id,
                    date: source.date,
                    type: source.type,
                    durationMinutes: source.durationMinutes,
                    estimatedCaloriesBurned: source.estimatedCaloriesBurned,
                    intensity: source.intensity,
                    notes: source.notes,
                    createdAt: source.createdAt,
                    updatedAt: source.updatedAt,
                    healthKitUUID: source.healthKitUUID,
                    logicalSessionID: source.logicalSessionID,
                    workoutOrigin: source.workoutOrigin,
                    energySource: source.energySource,
                    sourceBundleIdentifier: source.sourceBundleIdentifier,
                    sourceVersion: source.sourceVersion,
                    sourceRevision: source.sourceRevision,
                    deviceName: source.deviceName,
                    deviceModel: source.deviceModel,
                    dataQuality: source.dataQuality,
                    routeStatus: source.routeStatus,
                    routePointCount: source.routePointCount
                )
            },
            weightRecords: weights.map { source in
                .init(
                    id: source.id,
                    sourceActionKey: source.sourceActionKey,
                    measuredAt: source.measuredAt,
                    kilograms: source.kilograms,
                    source: source.source,
                    algorithmVersion: source.algorithmVersion,
                    createdAt: source.createdAt,
                    confidence: source.confidence,
                    healthKitSyncIdentifier: source.healthKitSyncIdentifier
                )
            },
            goalProfiles: goals.map { source in
                .init(
                    id: source.id,
                    profileKey: source.profileKey,
                    targetWeightKilograms: source.targetWeightKilograms,
                    dailyDeficitKcal: source.dailyDeficitKcal,
                    dailyProteinGrams: source.dailyProteinGrams,
                    effectiveFrom: source.effectiveFrom,
                    updatedAt: source.updatedAt
                )
            },
            dailyHealthSnapshots: healthSnapshots.map { source in
                .init(
                    id: source.id,
                    dayKey: source.dayKey,
                    timezoneID: source.timezoneID,
                    payloadData: source.payloadData,
                    snapshotHash: source.snapshotHash,
                    algorithmVersion: source.algorithmVersion,
                    createdAt: source.createdAt
                )
            },
            scheduleEvents: scheduleEvents.map { source in
                .init(
                    date: source.date,
                    title: source.title,
                    notes: source.notes,
                    startTime: source.startTime,
                    endTime: source.endTime,
                    createdAt: source.createdAt
                )
            },
            dailyBriefs: dailyBriefs.map { source in
                .init(
                    id: source.id,
                    cacheKey: source.cacheKey,
                    dayKey: source.dayKey,
                    snapshotHash: source.snapshotHash,
                    algorithmVersion: source.algorithmVersion,
                    payloadData: source.payloadData,
                    generatedAt: source.generatedAt
                )
            },
            weeklyBriefs: weeklyBriefs.map { source in
                .init(
                    id: source.id,
                    cacheKey: source.cacheKey,
                    weekKey: source.weekKey,
                    snapshotHash: source.snapshotHash,
                    algorithmVersion: source.algorithmVersion,
                    payloadData: source.payloadData,
                    generatedAt: source.generatedAt
                )
            },
            weeklyReports: weeklyReports.map { source in
                .init(
                    weekStartDate: source.weekStartDate,
                    weekEndDate: source.weekEndDate,
                    totalDeficitKcal: source.totalDeficitKcal,
                    avgDailyDeficitKcal: source.avgDailyDeficitKcal,
                    projectedWeightLossKg: source.projectedWeightLossKg,
                    avgProteinG: source.avgProteinG,
                    avgFatG: source.avgFatG,
                    avgCarbsG: source.avgCarbsG,
                    bestDay: source.bestDay,
                    worstDay: source.worstDay,
                    mealsCount: source.mealsCount,
                    workoutsCount: source.workoutsCount,
                    compliance: source.compliance,
                    generatedAt: source.generatedAt
                )
            },
            profileRevisions: profileRevisions.map { source in
                .init(
                    id: source.id,
                    profileKey: source.profileKey,
                    effectiveFrom: source.effectiveFrom,
                    dateOfBirth: source.dateOfBirth,
                    biologicalSex: source.biologicalSex,
                    heightCm: source.heightCm,
                    weightKg: source.weightKg,
                    activityLevel: source.activityLevel,
                    source: source.source,
                    createdAt: source.createdAt
                )
            },
            dailyMetricsProjection: dailyMetrics.map { source in
                .init(
                    date: source.date,
                    projectionVersion: source.projectionVersion,
                    sourceFingerprint: source.sourceFingerprint,
                    energyQuality: source.energyQuality,
                    requiresRecompute: source.requiresRecompute
                )
            },
            dailyCheckIns: dailyCheckIns.map { source in
                .init(
                    id: source.id,
                    sourceActionKey: source.sourceActionKey,
                    occurredAt: source.occurredAt,
                    energyRaw: source.energyRaw,
                    stressRaw: source.stressRaw,
                    subjectiveSleepRaw: source.subjectiveSleepRaw,
                    note: source.note,
                    sourceRaw: source.sourceRaw,
                    createdAt: source.createdAt
                )
            },
            userPreferences: userPreferences.map { source in
                .init(
                    id: source.id,
                    sourceActionKey: source.sourceActionKey,
                    categoryRaw: source.categoryRaw,
                    statement: source.statement,
                    sourceRaw: source.sourceRaw,
                    createdAt: source.createdAt
                )
            },
            mealPortionPriors: mealPortionPriors.map { source in
                .init(
                    id: source.id,
                    priorKey: source.priorKey,
                    foodID: source.foodID,
                    foodName: source.foodName,
                    unit: source.unit,
                    p10Grams: source.p10Grams,
                    p50Grams: source.p50Grams,
                    p90Grams: source.p90Grams,
                    sourceActionKey: source.sourceActionKey,
                    createdAt: source.createdAt,
                    updatedAt: source.updatedAt
                )
            }
        )
    }

    private func fetchAllRecords<Record: PersistentModel>(
        of type: Record.Type,
        in context: ModelContext,
        sortedBy sortDescriptors: [SortDescriptor<Record>]
    ) throws -> [Record] {
        var descriptor = FetchDescriptor<Record>(sortBy: sortDescriptors)
        descriptor.fetchLimit = Self.backupReadBatchSize
        var offset = 0
        var records: [Record] = []
        while true {
            descriptor.fetchOffset = offset
            let page = try context.fetch(descriptor)
            guard !page.isEmpty else { break }
            records.append(contentsOf: page)
            offset += page.count
            if page.count < Self.backupReadBatchSize { break }
        }
        return records
    }

    func checksum(for payload: BackupPayload) throws -> String {
        let digest = SHA256.hash(data: try encoder.encode(payload))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
